# Phase 2 native verification — Door Interaction (SPEC.md §2/§6.3, `Config.Features.DoorInteraction`)

Author: native-api-specialist (verification pass), jlwood17190665@gmail.com
Date: 2026-08-23
Scope: **research only, no `.lua` written.** This answers the specific question
asked by coder-frontend — what door natives really exist, what they really do,
and where the real gaps are — so Phase 2 door design isn't built on
misremembered natives.

Sources: verified against `citizenfx/natives` (the same source data that
backs docs.fivem.net/natives — `docs.fivem.net` and `forum.cfx.re` were both
unreachable through this session's egress proxy, so raw native definitions
were pulled directly from `raw.githubusercontent.com/citizenfx/natives`
instead; each native below is one I actually fetched and read, not one
recalled from memory). Where I could not fetch/confirm something, I say so
explicitly rather than fill the gap from memory.

---

## 0. Bottom line, up front

**Note added after initial draft:** this file was originally scoped against
a broader question ("can natives reliably tell locked from unlocked for any
door") than what SPEC.md §11.3/§11.5/§11.6 actually committed Phase 2 to
(detect a nearby door, confirm it's already safely nudge-able, play a
cosmetic push — with `nudgeRequiresUnlocked=true` as a hard
never-a-bypass guarantee, and no server-authoritative lock state at all).
**See §0.5 below for how these findings map onto that narrower, already-
conservative scope** before reading the rest of this document as "what
Phase 2 needs to do" — most of §1–4 is the full native picture, useful
background, but §0.5 is the part that answers the actual design question.

**The natives asked about in the task brief don't all exist as named.**
Specifically:

- `GetClosestDoorOfType` — **does not exist.** 404 on the natives repo.
  This looks like a conflation of two real, differently-shaped natives:
  `DoorSystemFindExistingDoor` (proximity lookup, needs a known model hash)
  and `GetStateOfClosestDoorOfType` (state lookup, needs a known door *type*
  hash, not a proximity search).
- `DoesDoorExist` — **does not exist.** 404 on the natives repo.
- `AddDoorToSystem`, `SetDoorState`-style natives — **these are real**, but
  the real name is `DoorSystemSetDoorState` (not `SetDoorState`), and
  `AddDoorToSystem` is real and confirmed (details below).
- `DoorSystemGetActive` — **real**, but I could only partially confirm it
  (docs.fivem.net page existed per search-engine indexing, but the page
  itself was unreachable through the egress proxy; details/caveat below).

So: yes, there is a real "door system" of natives, but it is narrower,
fussier, and less universally applicable than the task brief's naming
implied. This is exactly the kind of gap SPEC.md's §7 table is meant to
surface, and I'd recommend Phase 2 get its own version of that table with
this door row in it (draft at the bottom of this file).

---

## 0.5. Reconciling with SPEC.md §11.6's already-conservative scoping

**Read this section before §1–4 below** — after this file's first draft,
product-manager's real Phase 2 spec (SPEC.md §11.3/§11.5/§11.6) landed and
already scoped Door Interaction conservatively: `nudgeRequiresUnlocked =
true` is a **hard requirement** (nudge must never function as a lockpick
bypass, not just a default), nudge-open is **client-local only, no server
round-trip**, and §11.6 already concludes that reliable lock-state
detection for arbitrary map/MLO doors is "a genuine integration
dependency, not a pure scripting task" — i.e. Phase 2 does **not** need
this feature to reliably distinguish locked from unlocked doors across
every door on a server; it only needs to safely confirm "is *this*
door already open-to-walk-through" before playing a cosmetic push
animation. That's a narrower, safer target than "detect locked vs.
unlocked reliably for all door types," and everything below should be read
against that target, not the broader one.

Against that narrower target, here's how my native findings line up with
SPEC.md §11.6's claim:

- **SPEC.md §11.6 says:** "GTA has no generic native to query or set lock
  state on arbitrary map/interior doors... with no vanilla native surface
  at all to query it from outside that resource."
- **My finding, more precisely stated:** that's very slightly overstated —
  a native lock-state surface *does* exist (`DoorSystemGetDoorState`,
  `IsDoorClosed`, `GetStateOfClosestDoorOfType`, §1 below). But SPEC.md's
  practical conclusion is correct and, if anything, understates a real
  risk worth calling out explicitly: **that native surface only covers
  doors registered in GTA's own `CDoor` system** (mostly Rockstar's own
  IPL-authored interiors, plus anything a script explicitly registered via
  `AddDoorToSystem`). Most FiveM door-lock resources in the wild
  (`ox_doorlock`, `qb-doorlock`-style resources, and most custom MLO doors)
  do **not** use this native system at all — they implement their own lock
  flag as a database row plus manual object freeze/animation, entirely
  outside `CDoor`. So for exactly the doors a server's real door-lock
  resource manages — the doors this feature actually cares about — the
  native lock-state query is not just "unavailable," it can be
  **actively misleading**: a door a resource's own data considers
  "locked" may simply not be registered in the native `CDoor` system at
  all, in which case `IsDoorRegisteredWithSystem` returns false and
  `IsDoorClosed`/`DoorSystemGetDoorState` have nothing meaningful to say
  about it — reading that as "not locked, safe to nudge" would be a
  **real, concrete way to accidentally violate `nudgeRequiresUnlocked`'s
  hard guarantee**, not a theoretical one.
- **This confirms, and sharpens, SPEC.md §11.6's decision to scope
  nudge-open narrowly and defer real lock-state accuracy to a future
  door-lock-resource integration hook (§9 item 12)** rather than trusting
  the native `CDoor` lock-state natives as a stand-in for "is this door
  actually locked by whatever resource manages it." My recommendation:
  Phase 2 nudge-open should **not** call `DoorSystemGetDoorState`/
  `IsDoorClosed` and treat "not registered" or "state unlocked" as
  license to nudge. If it uses the native door system at all, it should
  be for the much safer, narrower "detect a nearby door entity to attach
  a push animation to" role — not as evidence about lock state — and
  actual gating on "already unlocked" should come from either (a) not
  gating on lock state at all and instead gating on whether the K9 can
  already physically walk through the door (i.e. don't touch the door
  object's state, just play an animation as the K9 pushes past an
  already-open/unlatched door — which needs no lock-state read at all and
  can't ever bypass anything, since nothing about the door's actual state
  is being changed), or (b) a real export hook from the server's specific
  door-lock resource, exactly as §9 item 12 already flags. Both are
  consistent with §11.6's own framing; (a) is the simpler, zero-integration-
  dependency version and is likely what "nudge-open... grants no real
  capability beyond what a player could already achieve by walking through
  an already-unlocked door normally" (§11.5) is describing in practice.

The rest of this document is the detailed native-by-native verification
that underlies the above — useful for confirming the door-*detection* and
door-*animation* natives work as described, and for anyone later scoping a
richer version of this feature that does take on a real door-lock
integration.

---

## 1. The real native inventory (all confirmed via `citizenfx/natives`)

All of these are `OBJECT` namespace natives, callable **client-side only**
(there is no server-side door-state authority in stock GTA/FiveM — more on
why that matters in §4).

| Native | Signature | Purpose | Confirmed |
|---|---|---|---|
| `AddDoorToSystem` | `void ADD_DOOR_TO_SYSTEM(Hash doorHash, Hash modelHash, float x, float y, float z, BOOL p5, BOOL scriptDoor, BOOL isLocal)` | Registers a door (a `CDoor`) with the door system under an arbitrary `doorHash` you pick, at a given model+coordinate. | Yes — `0x6F8838D03D1DC226` |
| `DoorSystemFindExistingDoor` | `BOOL DOOR_SYSTEM_FIND_EXISTING_DOOR(float x, float y, float z, Hash modelHash, Hash* doorOutPointer)` | Looks up whether a door **already registered** in the system exists at ~coordinates, for a **given model hash you must already know**. Search radius is a tight **0.5 units**. | Yes |
| `DoorSystemGetDoorState` | `int DOOR_SYSTEM_GET_DOOR_STATE(Hash doorHash)` | Reads back the lock-state int (see enum below) for a door you already have the `doorHash` for. | Yes |
| `DoorSystemSetDoorState` | `void DOOR_SYSTEM_SET_DOOR_STATE(Hash doorHash, int state, BOOL requestDoor, BOOL forceUpdate)` | Sets lock/open state by `doorHash`. Explicitly documented: lock states are **not applied and the networked `CNetObjDoor` is not created** until `DoorSystemGetIsPhysicsLoaded` returns true for that door. | Yes — `0x6BAB9442830C7F53` |
| `DoorSystemGetOpenRatio` | `float DOOR_SYSTEM_GET_OPEN_RATIO(Hash doorHash)` | Reads current "ajar" amount, presumably 0.0 closed → up to 1.0 open (sign/range not fully spelled out in the fetched doc). | Yes — `0x65499865FCA6E5EC` |
| `DoorSystemSetOpenRatio` | `void DOOR_SYSTEM_SET_OPEN_RATIO(Hash doorHash, float ajar, BOOL requestDoor, BOOL forceUpdate)` | Sets the ajar angle, **-1.0 to 1.0**, 0.0 = closed/default. This is the actual "push it open programmatically" native for a nudge/scratch interaction. | Yes — `0xB6E6FBA95C7324AC` |
| `DoorSystemSetHoldOpen` | `void DOOR_SYSTEM_SET_HOLD_OPEN(Hash doorHash, BOOL toggle)` | Forces a door to stay open. Doc notes an internal networking check around ownership/whether the door itself is networked. | Yes — `0xD9B71952F78A2640` |
| `GetStateOfClosestDoorOfType` | `void GET_STATE_OF_CLOSEST_DOOR_OF_TYPE(Hash type, float x, float y, float z, BOOL* locked, float* heading)` | Given a **door *type* hash** (not a specific door instance — this is one of ~225 known R*-defined interior door *types*) plus coordinates, reports whether the nearest matching door is locked, and its heading. | Yes |
| `SetStateOfClosestDoorOfType` | `void SET_STATE_OF_CLOSEST_DOOR_OF_TYPE(Hash type, float x, float y, float z, BOOL locked, float heading, BOOL p6)` | Sets lock/heading for the nearest door of that type. **Explicitly documented as "hardcoded to not work in multiplayer."** | Yes — but confirmed dead-on-arrival for FiveM |
| `IsDoorClosed` | `BOOL IS_DOOR_CLOSED(Hash doorHash)` | Boolean closed check by `doorHash`. | Yes |
| `IsDoorRegisteredWithSystem` | `BOOL IS_DOOR_REGISTERED_WITH_SYSTEM(Hash doorHash)` | Checks whether a given `doorHash` is currently registered at all — the correct guard before trusting any of the other by-hash natives. | Yes |
| `DoorSystemGetIsPhysicsLoaded` | `BOOL DOOR_SYSTEM_GET_IS_PHYSICS_LOADED(Hash doorHash)` | Whether the door's physics/network object has actually streamed in — gates whether `DoorSystemSetDoorState`/`SetOpenRatio` calls will actually take effect yet. | Yes |
| `RemoveDoorFromSystem` | `void REMOVE_DOOR_FROM_SYSTEM(Hash doorHash)` | Removes the door's *network object* but leaves the internal `CDoor`/`CDoorSystemData` association (hash↔model↔coords) allocated. | Yes |
| `DoorSystemGetDoorPendingState` | `int DOOR_SYSTEM_GET_DOOR_PENDING_STATE(Hash doorHash)` | Pending (not-yet-applied) state int, presumably relevant while `IsPhysicsLoaded` is still false. | Yes (return-value meanings not documented) |
| `DoorSystemGetActive` | *(FiveM-added, not a raw R\* native)* — returns a Lua/JS table of `{doorHash, doorHandle}` pairs for every door currently active in the system. | Enumerating what's *already registered*, for building your own proximity index instead of guessing model hashes. | **Partially confirmed** — indexed by docs.fivem.net and referenced consistently across independent sources, but I could not load the actual doc page (egress-blocked) to double check argument/return exactness. Treat the shape above as "very likely correct, not independently doc-verified this pass." |
| `DoorControl` (`_DOOR_CONTROL`) | 8 params: coords, `locked`, and per-axis rotation-speed multipliers | A different, older/lower-level door-manipulation native (not part of the `doorHash`-keyed system above). **Explicitly documented as hardcoded not to work in multiplayer**, same as `SetStateOfClosestDoorOfType`. | Yes — but dead-on-arrival for FiveM |

**`DoorSystemSetDoorState` lock-state enum** (confirmed from the fetched doc,
labeled "v323" — i.e. this is a decompiled/reverse-engineered enum, not an
officially published Rockstar enum, so treat numeric values as
well-established community knowledge rather than Rockstar-guaranteed):

```
0 = UNLOCKED
1 = LOCKED
2 = DOORSTATE_FORCE_LOCKED_UNTIL_OUT_OF_AREA
3 = DOORSTATE_FORCE_UNLOCKED_THIS_FRAME
4 = DOORSTATE_FORCE_LOCKED_THIS_FRAME
5 = DOORSTATE_FORCE_OPEN_THIS_FRAME
6 = DOORSTATE_FORCE_CLOSED_THIS_FRAME
```

State `5` (`DOORSTATE_FORCE_OPEN_THIS_FRAME`) or a `DoorSystemSetOpenRatio`
call is what a "nudge open" interaction would actually drive.

---

## 2. Answering the three concrete questions

### (a) Can a script reliably detect a nearby door object at all?

**Partially, and only for doors already known to the door system.** There is
no native that means "give me any door-like entity near these coordinates,
whatever it is." Every detection path requires you to already know either:

- a specific **model hash** (for `DoorSystemFindExistingDoor`, and it's a
  **0.5-unit radius** — you need to already be standing almost exactly on
  top of the registered coordinate, not just "in the room"), or
- a specific **door *type* hash** out of R*'s ~225-entry catalog of interior
  door types (for `GetStateOfClosestDoorOfType`/`SetStateOfClosestDoorOfType`
  — and the `Set` variant is confirmed dead in multiplayer anyway).

`DoorSystemGetActive` is the one genuinely useful *generic* detection tool:
it enumerates every door currently registered/active in the system as
`{doorHash, doorHandle}` pairs, with no need to know a model or type hash up
front. A K9 door-interaction feature would realistically want to:

1. Pull the active list from `DoorSystemGetActive`.
2. Resolve each `doorHandle` to coordinates (`GetEntityCoords` on the
   handle, since it's a genuine entity once physics is loaded).
3. Filter to whichever are within interaction range of the K9 ped.

This is workable but not free — it means iterating a system-wide list every
time you want to know "is there a door near me," rather than a single
targeted query. That's a real perf/design consideration to flag to
resource-performance-profiler if this runs on a tick thread rather than
on-demand at interaction time.

**The hard limit underneath all of this:** a "door" here specifically means
a `CDoor` object that something has registered with `AddDoorToSystem` (or
that Rockstar's own IPL/map data registered that way for shippable interior
doors). **Not every visual door prop in the game world is a `CDoor`.** Many
doors — plain decorative building doors on exterior facades, most doors that
are just static map geometry, and doors belonging to custom MLOs/interiors
added by a server unless that MLO's author explicitly registered them with
`AddDoorToSystem` — are **not in this system at all** and are invisible to
every native above. For those, a script sees only an inert prop (or nothing
scriptable at all, if it's baked into non-interactive map geometry) and
none of `DoorSystemFindExistingDoor`, `GetStateOfClosestDoorOfType`, or
`DoorSystemGetActive` will ever surface them.

Community-authored door-hash datasets exist (the door-lock resource
ecosystem — e.g. `ps-doorlock`/`qb-doorlock`/`esx_doorlock`-style resources —
generally ship a large datamined table of known `{model, coords}` pairs for
R*'s own interior doors, collected by prior community reverse-engineering
effort, not by any single native). Reusing or referencing such a dataset
(if this server already has a doorlock resource) would be a more reliable
detection path than a raw `GetClosestObjectOfType`-style scan for arbitrary
door props — but that's a data/asset dependency, not something the native
API alone gives you. I did not verify any specific dataset's accuracy or
license this pass; flagging it as a design option, not a confirmed
resource to adopt.

### (b) Can a script determine if a nearby door is locked?

**Yes, but only for a door you can already address by hash** — same
precondition as (a):

- `DoorSystemGetDoorState(doorHash)` — direct state read for a registered
  door you already have the hash for (e.g. from your own
  `AddDoorToSystem`/`DoorSystemGetActive` bookkeeping).
- `GetStateOfClosestDoorOfType(type, x, y, z, &locked, &heading)` — an
  out-parameter locked bool, but scoped to R*'s door-*type* catalog, not an
  arbitrary door.
- Guard with `IsDoorRegisteredWithSystem(doorHash)` first — calling the
  by-hash getters on an unregistered hash is meaningless.
- Guard with `DoorSystemGetIsPhysicsLoaded(doorHash)` too: the docs
  explicitly note lock state isn't even applied/networked until this
  returns true, so a check performed before the door has streamed in could
  read a stale or default value.

There is no ambiguity here once you have a valid `doorHash` — the read side
of the door system is solid. The gap is entirely upstream, in getting a
valid `doorHash` for an arbitrary door the K9 happens to be standing next
to.

### (c) Can a script open it programmatically?

**Yes, for a registered door, via `DoorSystemSetDoorState` (state `5`,
`DOORSTATE_FORCE_OPEN_THIS_FRAME`, or state `0`/unlock then let it swing) or
`DoorSystemSetOpenRatio` for a partial "nudged ajar" look**, with the same
physics-loaded caveat as above (`requestDoor`/`forceUpdate` params exist
specifically to help push the change through over the network — read the
signature notes in §1 for what each bool does).

**`SetStateOfClosestDoorOfType` and `DoorControl` are not usable for this at
all in FiveM** — both are explicitly documented upstream as hardcoded to
not function in multiplayer. This matters directly to the task brief, since
"open it programmatically" was one of the three things to verify, and one
of the two natives that sound like they'd do that turns out to be
non-functional in exactly the environment this resource runs in.

---

## 3. Real limitations, stated plainly (for the SPEC.md §7-style table)

1. **Coverage gap is the central problem.** GTA V's door system was built
   for Rockstar's own interiors, not as a general "every door is
   scriptable" API. A door not registered via `AddDoorToSystem` (by R*'s own
   IPL data, or by a script) simply does not exist to any native in this
   family — there is no fallback "detect any door-shaped prop" native.
2. **Proximity detection is either extremely tight (0.5 units,
   `DoorSystemFindExistingDoor`) or requires already knowing a type/model
   hash** — there's no "what's near me" query with a normal interaction
   radius (a few meters) built in. `DoorSystemGetActive` + manual distance
   filtering is the closest thing to that, at the cost of enumerating the
   whole active list yourself.
3. **Custom MLOs/interiors are exactly the scenario most likely to be
   invisible to this system**, since their doors are only registered if the
   MLO's author explicitly called `AddDoorToSystem` for them — not
   guaranteed for any given community MLO a server installs.
4. **Two door-manipulation natives that look relevant are dead in FiveM
   specifically** (`SetStateOfClosestDoorOfType`, `DoorControl`) —
   single-player-only, by Rockstar's own hardcoding, not a FiveM
   restriction that might get lifted.
5. **Streaming/physics-load timing is a real gotcha**: state changes on a
   door whose `DoorSystemGetIsPhysicsLoaded` is still false won't take
   effect or network correctly — a "scratch at a locked door" interaction
   needs to check this before trusting a read, and possibly retry/queue a
   write.
6. **No server-side authority exists in this native family at all.** Every
   native above is client-only; if Phase 2 wants door-lock state to be
   consistent across all clients (so the K9's handler and everyone else
   sees the same open/closed door), that synchronization has to be built by
   this resource itself (e.g. a server event broadcasting the intended
   state change to all clients, each of which calls
   `DoorSystemSetDoorState` locally) — the native layer doesn't do this for
   you, unlike `requestDoor`/`forceUpdate`'s partial help with the
   *networked entity* side of a single door once it's already registered.
7. **Reverse-engineered enum, not an official Rockstar-published one.** The
   lock-state integers in §1 come from community decompilation
   (labeled "v323" in the source doc), which is normal and reliable
   FiveM-ecosystem practice, but worth stating rather than presenting as
   Rockstar-guaranteed API.

---

## 4. Practical recommendation for coder-frontend's design

**Primary recommendation (matches SPEC.md §11.3/§11.5/§11.6's shipped
scope — see §0.5 above):** don't use the native `CDoor` lock-state natives
to gate `nudgeRequiresUnlocked` at all. Use them only for the cosmetic
"is there a door-shaped entity near me to animate" role if wanted, and
implement the actual "safe to nudge" condition as "don't change or read
lock state — just play the K9's push animation as it passes through a
door the player can already physically walk through," which structurally
cannot violate the hard no-bypass guarantee because it never touches the
door's lock state at all. This is fully client-local, native-only (basic
`GetEntityCoords`/animation-task natives, not the door-system natives),
and needs no door-lock-resource integration decision — matching §11.5's
own description of nudge-open as granting "no real capability beyond what
a player could already achieve by walking through an already-unlocked
door normally."

The rest of this section (below) describes the **richer, not-currently-
scoped** version of this feature that *would* use the real `CDoor`
lock-state system end to end — useful if a later phase wants to revisit
lock-state-aware nudging for the narrower set of doors that genuinely are
`CDoor`-registered, but out of scope for what Phase 2 actually committed
to per §11.6.

Given the above, a fuller (not currently scoped) "Door Interaction" design
against the native `CDoor` system, for doors that are actually registered
in it, should:

- **Not assume every visual door the K9 can walk up to is interactable.**
  The feature's own acceptance criteria should explicitly scope to "doors
  registered in the door system" (R*'s own building interiors, plus any MLO
  the server owner has confirmed registers its doors), not "any door."
- Use `DoorSystemGetActive` once (cached, refreshed periodically or on
  demand rather than every tick) to build a lookup of registered doors, then
  do local distance filtering client-side against the K9's own position for
  actual proximity detection — this sidesteps needing to know model/type
  hashes ahead of time for detection, at the cost of a coarser "how often do
  we refresh the active list" design question (a resource-performance-
  profiler question, not one I'm answering here).
- Gate the "nudge open" action on `DoorSystemGetDoorState(doorHash) == 0`
  (unlocked) and drive it via `DoorSystemSetOpenRatio`/`SetDoorState(...,
  5, ...)`; gate the "scratch to alert" action on state `1` (locked) —
  both guarded by `IsDoorRegisteredWithSystem` and
  `DoorSystemGetIsPhysicsLoaded` checks first.
- Explicitly document (in whatever this feature's own version of a §7
  row becomes) that doors outside the door system are a known, permanent
  gap — not a bug to chase — same posture SPEC.md already takes for things
  like the camera PiP feed.

Suggested table row for Phase 2's own §7-style table:

| Requested item | Native-only approximation (what ships) | What would actually need more than natives |
|---|---|---|
| Door interaction (nudge open unlatched / scratch at locked) | Fully native for any door already registered in GTA's door system: read lock state via `DoorSystemGetDoorState`/`GetStateOfClosestDoorOfType`, open via `DoorSystemSetDoorState`/`DoorSystemSetOpenRatio`, detect proximity via `DoorSystemGetActive` + distance filtering (or a known model/type hash). Sync across clients needs this resource's own server-broadcast event, since the door natives are client-only. | Any door not registered with the door system (most exterior facade doors, most custom MLOs unless their author explicitly called `AddDoorToSystem`, and any purely decorative door prop) is invisible to this feature entirely — there is no native fallback to detect or manipulate those. Extending coverage to a specific server's custom interiors would need either that MLO's author adding `AddDoorToSystem` calls, or adopting/maintaining a community-sourced door-hash dataset as static config data (not a native-API solution). |

---

## 5. What I could not verify this pass

- `DoorSystemGetActive`'s exact signature/return shape (docs.fivem.net page
  blocked; cross-referenced against consistent third-party summaries only,
  not the primary source doc itself).
- Any forum.cfx.re discussion of real-world reliability quirks (e.g. known
  bugs, specific door-type hash lists) — `forum.cfx.re` was also blocked by
  the egress proxy this session, so I could not read the community guide
  thread ("Lock doors like a boss...") that would likely have had more
  practical caveats and a link to a community door-hash dataset.
- Whether `GetStateOfClosestDoorOfType` (the *read*-only half) shares the
  same "hardcoded to not work in multiplayer" restriction as its `Set`
  counterpart — the fetched doc for the `Get` native did not state this
  either way, and I'm not confident enough from general knowledge to assert
  it works in MP. **Treat this native's MP reliability as unconfirmed
  rather than assumed-working** until someone can test it in-session or
  reach the blocked doc/forum sources.

If coder-frontend needs either of those closed out before finalizing the
design, I'd suggest either an in-session native test (spawn near a known
interior door, call `GetStateOfClosestDoorOfType` with a known type hash,
and observe) or another attempt at reaching docs.fivem.net/forum.cfx.re
through a different path, since I've exhausted the direct-fetch routes
available to me this pass.
