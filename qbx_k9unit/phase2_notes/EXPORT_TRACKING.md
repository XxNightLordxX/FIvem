# qbx_k9unit — Phase 2 Public-Surface Tracking

Owner: api-contract-agent. Living document — updated as phase2_notes/*.md
files appear. Purpose: catch (a) collisions against the existing Phase 1
namespace, (b) collisions between two independent Phase 2 proposals, and
(c) near-duplicate helpers that should be merged into one shared utility
before real code gets written.

Status: LIVE — polling phase2_notes/ as design notes land. Last updated
after `thermal_night_vision_natives.md` appeared (native-verification note,
no proposed function/event names of its own — see log below).

## Files seen so far / log

- `water_gunpowder_tracking.md` (coder-frontend) — **written before SPEC.md
  §11 existed** (says so explicitly: "written ahead of product-manager's
  detailed Phase 2 scoping pass"). Deliberately proposes no locked event/
  function names ("illustrative event/state names below are proposals... not
  a locked contract") — nothing to collision-check by exact name yet. One
  real divergence from §11.3's file plan worth watching through
  reconciliation: this note suggests splitting tracking across "a new
  `client/tracking.lua` (scent + water) and either a shared or separate file
  for gunpowder," whereas §11.3 already assigns **scent + blood + gunpowder +
  the water-crossing modifier all to one file**, `client/tracking.lua`. Not
  flagging as a hard collision yet since this note predates §11 and the
  coordinator has since sent this pair the §11 excerpt to reconcile against
  — expect the reconciled version to drop the split-file suggestion and
  adopt §11.3's single-file plan. Will re-check once a reconciled/updated
  version of this note (or an implementation-ready contract) appears.
- `scent_blood_natives.md` (native-api-specialist) — native-verification
  research only, no proposed function/event names, nothing to track by name.
  Confirms `DrawMarker`/water-height natives are client-only (server can't
  validate trail geometry itself) — worth cross-referencing once
  `server/tracking.lua`'s actual contract is written, since §11.4's
  `findTrackableSource` callback returns `coords`/`breaksAtWater` from the
  server, meaning the server only ever hands back a *source coordinate*, not
  a full waypoint path — client-side trail rendering (this note's §1) is
  therefore entirely a client concern building on that one coordinate, which
  matches §11.3's split cleanly (no action needed, just confirming
  consistency).
- `thermal_night_vision_natives.md` — native-verification note (paired with
  the thermal/night-vision design note, not yet seen). Confirms
  `SetNightvision(bool)`/`IsNightvisionActive()` for night vision and
  `SetSeethrough(bool)`/`IsSeethroughActive()` for thermal (correcting
  SPEC.md §7/§6.3's `SetTimecycleModifier` attribution — good catch,
  consistent with SPEC.md §11.6's own independent correction to the same
  native). No exported function/event names proposed in this file itself —
  nothing to track yet from it. Watching for its paired design note to
  propose the actual toggle function names (open naming slot #1 in the
  baseline section below).

## Phase 1 contract (existing namespace — Phase 2 must not collide with or
duplicate any of this)

### Resource-global Lua functions (no `local`)

| Name | Side | File | Signature |
|---|---|---|---|
| `IsOwnModelK9` | client | client/main.lua | `() -> boolean` — display-only self model check |
| `HasK9Access` | client | client/main.lua | `() -> boolean` — awaits server callback for local player, TTL-cached ~1000ms |
| `CanShowK9UI` | client | client/main.lua | `() -> boolean` — combinator `IsOwnModelK9() and HasK9Access()`; THE gating call for other client files |
| `ToggleK9Camera` | client | client/movement.lua | `()` — first/third person eye-height toggle |
| `K9Sit` | client | client/movement.lua | `()` — self-emote, gated by `CanShowK9UI()` |
| `RequestLeashAttach` | client | client/movement.lua | `(targetPlayerServerId: number)` — sends consent request only |
| `DetachLeash` | client | client/movement.lua | `()` — zero-consent, always available while leashed |
| `IsLeashed` | client | client/movement.lua | `() -> boolean` |
| `EnterNearestK9Vehicle` | client | client/vehicle.lua | `()` |
| `ExitK9Vehicle` | client | client/vehicle.lua | `()` |
| `IsInK9Vehicle` | client | client/vehicle.lua | `() -> boolean` |
| `HasK9Access` | **server** | server/certifications.lua | `(source: number) -> boolean` — SAME NAME as the client one above but different Lua VM; documented as intentional mirrored-name, not a real collision. Any Phase 2 server-side global also named `HasK9Access` WOULD collide with this one (same VM) — do not reuse. |
| `IsConfiguredK9Model` | server | server/certifications.lua | `(modelHash: number) -> boolean` |
| `RefreshCertificationCache` | server | server/certifications.lua | `(citizenid: string, jobName: string)` |
| `ForceDetachLeashForSource` | server | server/main.lua | `(src: number, reason: string?) -> boolean` |
| `ForceDetachOfficerLeashForSource` | server | server/main.lua | `(src: number, reason: string?) -> boolean` |

### Events

| Event | Direction | File | Payload |
|---|---|---|---|
| `qbx_k9unit:server:hasK9Access` | callback (client->server) | server/certifications.lua | `() -> boolean` |
| `qbx_k9unit:server:certifyHandler` | client->server | server/certifications.lua | `(targetServerId: number)` |
| `qbx_k9unit:server:revokeHandler` | client->server | server/certifications.lua | `(targetServerId: number)` |
| `qbx_k9unit:server:relayBark` | client->server | server/main.lua | `(barkType: string)` |
| `qbx_k9unit:client:playBark` | server->client | client/main.lua | `(netId: number, barkType: string)` |
| `qbx_k9unit:server:requestLeashAttach` | client->server | server/main.lua | `(targetServerId: number)` |
| `qbx_k9unit:server:respondLeashAttach` | client->server | server/main.lua | `(fromServerId: number, accepted: boolean)` |
| `qbx_k9unit:server:detachLeash` | client->server | server/main.lua | `()` |
| `qbx_k9unit:client:leashAttachRequest` | server->client | client/movement.lua | `(fromServerId: number)` |
| `qbx_k9unit:client:leashAttached` | server->client | client/movement.lua | `(partnerServerId: number, isConstrained: boolean)` |
| `qbx_k9unit:client:leashDetached` | server->client | client/movement.lua | `(reason: string)` |

### ox_target option names already registered (own private namespace, but
worth tracking since Phase 2 features will likely add more)

`qbx_k9unit:attachLeash`, `qbx_k9unit:certifyHandler`, `qbx_k9unit:revokeHandler`
(addGlobalPlayer, client/movement.lua); `qbx_k9unit:enterVehicle`,
`qbx_k9unit:exitVehicle` (addGlobalVehicle, client/vehicle.lua).

### Known internal-only patterns other than exposed globals
`ox_lib` radial item ids (`k9unit`, `k9_sit`, `k9_bark`, `k9_leash`,
`k9_vehicle`) in client/radial.lua — internal wiring, not a cross-resource
contract, but Phase 2 radial items must pick new, non-colliding ids too.

### Naming convention observed
- Resource-global functions: PascalCase verb-first (`IsX`, `HasX`, `CanX`,
  action verbs like `ToggleX`/`RequestX`/`DetachX`/`EnterX`/`ExitX`).
- Events: `qbx_k9unit:server:<verbNoun>` (client->server) and
  `qbx_k9unit:client:<verbNoun>` (server->client), camelCase after the
  second colon.
- Phase 2 proposals should follow both conventions so a reviewer can tell
  direction (client/server) and side (client-global vs server-global) from
  the name alone.

## Pre-existing Phase 2 baseline (SPEC.md §11, product-agent, dated same day)

SPEC.md already contains a detailed Phase 2 spec (§11) written by
product-agent *before* the five phase2_notes design pairs started — this
is the reference architecture the design notes are implicitly extending,
not a blank slate. Treat any design-note proposal that diverges from this
without comment as worth double-checking (may be an intentional refinement
the note should call out, or may be an accidental drift/duplicate). This
also means "collision with Phase 1" isn't the only prior baseline to check
against — it's Phase 1 (client/server files) + this §11 baseline.

**Already-named callbacks:**
- `qbx_k9unit:server:findTrackableSource` (trackType: 'scent'|'blood'|'gunpowder') -> `{found, coords, breaksAtWater}` [server/tracking.lua]
- `qbx_k9unit:server:searchTarget` (targetType: 'vehicle'|'person', targetNetId: number) -> `{ok, reason?, contrabandFound?, totalWeight?, alertTier?}` [server/search.lua]

**Already-named server events (client->server):**
- `qbx_k9unit:server:relayDamageEvent` () [server/tracking.lua] — blood source
- `qbx_k9unit:server:relayWeaponFire` () [server/tracking.lua] — gunpowder source
- `qbx_k9unit:server:relayDoorScratch` (doorNetId: number) [server/main.lua]

**Already-named client event (server->client):**
- `qbx_k9unit:client:playDoorScratch` (netId: number) [client/movement.lua]

**Already-named/implied client globals (file plan, §11.3):**
- `client/tracking.lua`: `StartScentTrack()`, `StartBloodTrack()`, `StartGunpowderTrack()` — explicitly named, called from client/radial.lua's three new items
- `client/search.lua`: ox_target-based, no named resource-global specified yet
- `client/vision.lua`: toggle keybinds mirroring `ToggleK9Camera`'s shape — no exact function name given yet in §11 (open naming slot — first design note to touch vision should pick e.g. `ToggleThermalVision()`/`ToggleNightVision()` and other vision notes should match, not invent a second pair)
- `client/movement.lua` (extends): door nudge/scratch — no exact function name given yet in §11 (open naming slot — likely `TryNudgeDoor()`/`ScratchDoor()` or similar; whichever design note covers door interaction should name these once, since movement.lua already exists and any name chosen here also needs to not collide with movement.lua's existing `ToggleK9Camera/K9Sit/RequestLeashAttach/DetachLeash/IsLeashed`)

**File plan (§11.3) — new files expected:** `client/tracking.lua`,
`client/search.lua`, `client/vision.lua` (new), `server/tracking.lua`,
`server/search.lua` (new); `client/movement.lua` and `server/main.lua`
extended in place. Two design notes both proposing to own "door
interaction" logic in different files, or a vision note proposing to fold
into movement.lua instead of a new vision.lua, would be worth flagging as
drift from this already-agreed file plan (not necessarily wrong, but
should be a deliberate deviation, not an accident from not having read
§11).

**Open naming slots explicitly left by §11 for the design notes to fill
(watch these for two different notes independently inventing two
different names for the same slot):**
1. Vision toggle function names (thermal + night).
2. Door nudge/scratch function names.
3. `client/search.lua`'s exposed resource-global(s), if any (or confirmation it's ox_target-only with no exposed global, mirroring how vehicle.lua's ox_target options call vehicle.lua's own globals).
4. Exact ox_target option `name` strings for search-vehicle/search-person/door-nudge/door-scratch (Phase 1 convention: `qbx_k9unit:<verbNoun>`, e.g. `qbx_k9unit:searchVehicle`).

## Phase 2 proposed surface — running inventory (from phase2_notes/*.md)

_None yet. Table below will be populated as phase2_notes/*.md files appear._

| Proposed name | Kind | Proposing note | Status |
|---|---|---|---|

## Batch 2 — full design notes landed (pre-§11-reconciliation snapshot)

All five of `scent_blood_tracking.md`, `thermal_night_vision.md`,
`door_interaction.md`, `door_interaction_natives.md`,
`water_gunpowder_natives.md` were written **before** SPEC.md §11 existed
(each says so explicitly — "Phase 2 is not spec'd in detail yet"). Per the
coordinator's update, each pair has since been sent the §11 excerpt to
reconcile against. This section is a snapshot of what they proposed
*before* that reconciliation, flagging exactly what would need to change to
match §11 — will re-check once updated/reconciled versions land.

### `scent_blood_tracking.md` (coder-architect) — DIVERGES from §11.3/§11.4, needs reconciliation

Proposed (pre-§11):
- Client globals: `StartScentTracking()`, `StartBloodTracking()`,
  `StopTracking()`, `IsTracking() -> boolean` [client/tracking.lua]
- Server callbacks: **two separate** `qbx_k9unit:server:findNearestScentSource`
  and `qbx_k9unit:server:findNearestBloodSource` (one per trail type)

§11.3/§11.4 (authoritative, landed same day but this note didn't have it
yet):
- Client globals: `StartScentTrack()`, `StartBloodTrack()`,
  `StartGunpowderTrack()` [client/tracking.lua] — **different verb form**
  (`...Track` vs. this note's `...Tracking`) and §11 has no `StopTracking()`/
  `IsTracking()` named yet (open slot this note fills, reasonably).
- Server callback: **one parameterized** `qbx_k9unit:server:findTrackableSource(trackType: 'scent'|'blood'|'gunpowder')`
  — a single callback for all three trail types, not one per type.

Two concrete deviations to flag for reconciliation, not just naming taste:
1. **Function name form** (`StartScentTracking` vs `StartScentTrack`,
   likewise Blood) — cosmetic but must be picked once, not shipped as two
   near-identical names; §11.3 explicitly names `client/radial.lua`'s three
   new items as calling `StartScentTrack()`/`StartBloodTrack()`/
   `StartGunpowderTrack()` verbatim, so radial.lua's contract depends on
   which form wins.
2. **One callback vs. three** — architecturally different, not just a
   naming quibble: §11.4's single `findTrackableSource(trackType)` shape
   means `server/tracking.lua` has one registration and one gunpowder path
   falls out "for free" once scent/blood exist; this note's two-callback
   proposal (written before gunpowder was in scope for this note at all)
   would need a third `findNearestGunpowderSource` grafted on to stay
   consistent with itself, duplicating the re-validation/proximity/cooldown
   logic three times instead of once. §11.4's shape is very likely the one
   to converge on (matches §11.1's sub-phase-2e "avoids two divergent copies
   of that infrastructure" reasoning applied one level up).

Not flagging as a currently-live collision requiring an interrupt — this
note predates §11 by design and the coordinator has already routed §11 to
this pair. Logged here so the final pass can confirm the reconciled version
actually adopts §11.4's single-callback/exact-name shape rather than
partially merging the two.

### `thermal_night_vision.md` (coder-frontend) — fills an open naming slot correctly, one still-open behavioral question

Proposes `ToggleThermalVision()`, `ToggleNightVision()`,
`IsThermalVisionActive()`, `IsNightVisionActive()` in a new `client/vision.lua`
— this is exactly the open naming slot flagged in this doc's baseline
section, no other design note proposed competing names for it, and the file
placement matches §11.3's file plan (`client/vision.lua`, new) exactly. **No
collision.** Native names (`SetSeethrough`/`SetNightvision`) match both
native-verification notes (`thermal_night_vision_natives.md` and
`water_gunpowder_natives.md`'s §3, independently) and SPEC.md §11.6's own
correction — three independent sources now agree.

One still-open behavioral question, not a naming collision but worth
carrying into the final validation pass: this note picks `CanShowK9UI()`
(the certified-access gate) over the cheaper `IsOwnModelK9()` local-only
check for vision toggles, with explicit reasoning. SPEC.md §11.5 itself
flags this exact question as unresolved and *leans the opposite way*
(toward `IsOwnModelK9()` only, for camera-toggle consistency) but says
"resolve before implementation, do not guess." Two documents now hold
opposite leans on the same open question — not a name collision, but a
real behavioral fork that needs one explicit resolution before
`client/vision.lua` is implemented, not an accidental pick from whichever
document a coder reads first.

### `door_interaction.md` (coder-frontend) + `door_interaction_natives.md` (native-api-specialist) — mostly consistent with §11, one unresolved scope question

The design note's own sketch (§7, "not committed") — `qbx_k9unit:server:relayDoorScratch`
— matches §11.4 item 5's exact name. No collision. Nudge-open being
client-only-with-no-event also matches §11.3/§11.4/§11.6 exactly
(independently arrived at the same design both times). The native-verification
note materially corrects the door-system native names both `door_interaction.md`'s
own checklist *and* SPEC.md's implicit assumptions guessed at (e.g.
`DoesDoorExist`/`GetClosestDoorOfType` don't exist; real names are
`IsDoorRegisteredWithSystem`/`DoorSystemFindExistingDoor`, and
`SetStateOfClosestDoorOfType`/`DoorControl` are confirmed dead in
multiplayer) — this should feed back into whoever finalizes `Config.K9Doors`-
style config, flagged for coder-backend/coder-architect per the note's own
request, not something this tracking pass needs to relay further.

Genuinely open, not resolved by §11: **who receives the "scratch to alert"
broadcast** — the design note raises leash-partner-only vs. broader
on-duty-radius dispatch as an explicit fork needing coder-backend's
sign-off; §11.3/§11.4 only say the event is "structurally identical to
relayBark" (which broadcasts to literally everyone, `TriggerClientEvent(...,
-1, ...)`) without addressing whether door-scratch should instead be
targeted. Worth flagging in the final validation pass: if the reconciled
contract doc ships a targeted broadcast, that's a deviation from §11.3's
"identical to relayBark" framing that should be called out explicitly
(reasonable deviation, but should be a stated decision, not a silent one).

### `water_gunpowder_natives.md` (native-api-specialist) — verification only, no names proposed, no collision

Confirms `GetWaterHeightNoWaves` (preferred over `GetWaterHeight` for
frame-stability) and `IsPedShooting` + coordinate-on-transition (preferred
over the undocumented `CEventGunShot` game-event family) as the concrete
mechanisms backing §11.4 items 3/4's `relayDamageEvent`/`relayWeaponFire`
groundwork. No exported names of its own to track. Also independently
reconfirms the `SetNightvision`/`SetSeethrough` correction a third time —
three independent verification passes now agree, worth noting as
resolved/settled rather than needing a fourth check.

## FINAL VALIDATION PASS — design notes vs. SPEC.md §11 as source of truth

Per the coordinator's mid-task direction: this pass validates every design
note's proposed name/file against §11.3's file plan and §11.4's exact
event/callback names as the authoritative contract, not just checking the
five notes against each other. **As of this pass, no reconciled/updated
versions of any design note have appeared in `phase2_notes/`** — the file
list has been stable (same 9 files + this tracking doc) across many repeated
checks, and my direct SendMessage attempts to the authoring agents
(coder-architect, coder-security, coder-backend) all returned "no agent
reachable," consistent with what several of the notes themselves report
attempting and failing. So this validation is against the notes **as
currently written**, which per their own timestamps predate §11 — treat the
"MISMATCH" rows below as the reconciliation work still outstanding, not as
a currently-shipping contract violation.

| §11 file/name | Design note | Match? |
|---|---|---|
| `client/tracking.lua` (new), owns scent+blood+gunpowder+water-modifier | `scent_blood_tracking.md` proposes this file for scent+blood ✓; `water_gunpowder_tracking.md` (older, vaguer) suggested possibly splitting gunpowder into a separate/shared file | **PARTIAL MATCH** — scent_blood_tracking.md's file placement is correct; water_gunpowder_tracking.md's file-split suggestion is superseded/should not be followed |
| `StartScentTrack()` / `StartBloodTrack()` / `StartGunpowderTrack()` (§11.3, called from client/radial.lua) | `scent_blood_tracking.md` proposes `StartScentTracking()` / `StartBloodTracking()` | **MISMATCH** — verb form differs (`Track` vs `Tracking`); must converge to §11.3's exact names since §11.3 already wires radial.lua to call them verbatim |
| `qbx_k9unit:server:findTrackableSource(trackType)` — one callback for all three types (§11.4 item 1) | `scent_blood_tracking.md` proposes **two** callbacks, `findNearestScentSource` / `findNearestBloodSource` | **MISMATCH** — architecture (one parameterized callback vs. per-type callbacks), not just a name; see full writeup below |
| `client/vision.lua` (new) | `thermal_night_vision.md` | **MATCH** |
| Thermal/night vision toggle fn names — not named in §11, open slot | `ToggleThermalVision()` / `ToggleNightVision()` / `IsThermalVisionActive()` / `IsNightVisionActive()` | **MATCH** (fills the open slot, nothing to conflict with) |
| `client/movement.lua` extends for door nudge/scratch; `server/main.lua` extends for `relayDoorScratch` only | `door_interaction.md` | **MATCH** |
| `qbx_k9unit:server:relayDoorScratch(doorNetId)` (§11.4 item 5) | `door_interaction.md`'s own sketch names exactly this | **MATCH** |
| `qbx_k9unit:client:playDoorScratch(netId)` (§11.4 item 6) | Not named in `door_interaction.md` (deferred) | **NO CONFLICT** (open slot, not yet filled) |
| `qbx_k9unit:server:searchTarget(targetType, targetNetId) -> {ok, reason?, contrabandFound?, totalWeight?, alertTier?}`, one `lib.callback` (§11.4 item 2) | `contraband_search_security_review.md` proposes **two events**, `requestContrabandSearch`/`contrabandSearchResult`, and a **blocking rule against ever sending totalWeight** | **MISMATCH** — both architecture (callback vs. event-pair) and payload (tier-only vs. §11.4's explicit `totalWeight` field, which §11.5's acceptance criteria also relies on) |
| `server/search.lua` (new), `client/search.lua` (new) | Not explicitly named in the security review (it discusses the feature, not file placement) | **NO CONFLICT** (file plan not addressed either way) |

### Outstanding, unresolved after this pass

1. **`scent_blood_tracking.md` vs. §11.3/§11.4** — naming-form and
   single-vs-multiple-callback divergence. Flagged directly to
   coder-architect via SendMessage (unreachable — see above); logged here
   for whoever reconciles next.
2. **`contraband_search_security_review.md` vs. §11.4** — the most
   consequential open mismatch (architecture + payload shape), and the
   contract doc that was supposed to reconcile it
   (`contraband_search_contract.md`, referenced by name inside the security
   review itself) never appeared in `phase2_notes/` during this task's
   observation window. This is the single highest-priority item for
   whoever picks this up next: **do not implement `server/search.lua`
   against either document in isolation** — reconcile against §11.4 first
   (recommended resolution already proposed in both SendMessage attempts
   above: §11.4's single callback shape, `totalWeight` visible only in the
   private response to the requesting K9, tier-only for the
   broadcast-to-bystanders alert).
3. **Vision access-gating fork** (`CanShowK9UI()` vs. `IsOwnModelK9()`) —
   not a naming collision, but an unresolved behavioral question §11.5
   itself flags as needing an explicit decision before implementation;
   `thermal_night_vision.md` picked one side without that decision having
   been made yet.
4. **Door-scratch broadcast recipient scope** (leash-partner-only vs.
   broader on-duty dispatch) — raised by `door_interaction.md`, not
   addressed by §11.3/§11.4 either (which only say "structurally identical
   to relayBark," implying broadcast-to-everyone by default). Needs an
   explicit decision, not a default inherited silently from relayBark's
   shape.

## Collisions / duplication flagged

### 1. OPEN — `contraband_search_security_review.md` (coder-security) proposes an event shape that CONTRADICTS SPEC.md §11.4's already-established contract for the same feature

**Severity: high — needs resolution before `contraband_search_contract.md` (coder-backend's contract doc, referenced but not yet written) is finalized.**

SPEC.md §11.4 item 2 (written same day by product-agent, *before* this
security review) already specifies:

```
qbx_k9unit:server:searchTarget (targetType: 'vehicle'|'person', targetNetId: number)
  -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
  [lib.callback, server/search.lua]
```

i.e. a single **request/response `lib.callback`**, matching the exact
convention `hasK9Access` already established in Phase 1 (§11.4 item 7
explicitly reasons about this: "No dedicated client event is needed for
tracking-result or search-result delivery... `lib.callback` is the correct
fit").

`contraband_search_security_review.md` (coder-security), written without
apparent awareness of §11.4 (the doc's own status note says it derived
requirements "from those sections plus the security patterns already
established" but does not cite §11.4 specifically, and proposes a
structurally different shape), instead proposes a **two-event
request/response pair**:

```
qbx_k9unit:server:requestContrabandSearch (client->server, target id only)
qbx_k9unit:client:contrabandSearchResult   (server->client, tier only)
```

Two concrete contradictions between the two documents, not just a naming
difference:
1. **Callback vs. event-pair.** SPEC.md §11.4 uses one `lib.callback`
   (`searchTarget`); the security review's §1 proposes two separate
   `RegisterNetEvent`s instead. Whichever coder-backend actually implements,
   the OTHER becomes a phantom/unused name in the tracking inventory and a
   possible source of two divergent client call sites if both design notes
   get partially followed.
2. **Payload shape — `totalWeight` in the response.** SPEC.md §11.4's
   callback return shape explicitly includes `totalWeight: number?`. The
   security review's §4 is a **blocking requirement that the response must
   be tier-only and must NEVER include "exact weights"** — directly
   contradicting §11.4's shape as written. This is a real, substantive
   security-vs-spec disagreement (not just a naming quibble) that needs an
   explicit decision, not silent resolution either way: does the requesting
   K9's own client get told the raw computed weight (useful for e.g. a
   "large stash" HUD readout) or only the derived tier string? SPEC.md
   §11.5's acceptance criteria for search also says "reports
   `contrabandFound`/`totalWeight` to the requesting K9 player" even when
   `ContrabandAlerts` is off — so §11.4/§11.5 together clearly intend
   `totalWeight` to reach the requesting client; the security review's
   blocking requirement would break that acceptance criterion as written.
   Likely reconcilable (broadcast-to-nearby-players alert = tier-only per
   the security review's actual threat model of "other players
   overhearing"; response-to-the-requesting-K9-only = can safely include
   totalWeight since it's their own request) — but that distinction isn't
   drawn explicitly in either document yet, and coder-backend's contract
   doc needs to draw it rather than pick one document to follow blindly.

Action taken: attempted to flag directly to coder-security and coder-backend
via SendMessage while both are plausibly still active; both attempts
returned "No agent named ... is reachable" (consistent with the security
review's own reported experience trying to reach coder-backend/team-leader).
**Update (coordinator message received):** the top-level session has now
sent each of the five design pairs the relevant SPEC.md §11 excerpt
directly to reconcile against, and asked this tracking pass to validate
the *reconciled* notes against §11 as the authoritative source (not just
check pairs against each other). Re-checking this specific conflict once
`contraband_search_contract.md` (or an updated
`contraband_search_security_review.md`) appears — expect it to converge on
§11.4's `qbx_k9unit:server:searchTarget` callback shape now that coder-backend
has been given §11 directly; will confirm and update status below once seen.

## Near-duplicate helper candidates (should share one implementation)

_None yet — watching specifically for: "find nearest door", "find nearest
vehicle", "find nearest ped/player" style local scan helpers across the
five Phase 2 designs (scent/blood tracking, water/gunpowder tracking,
contraband search, door interaction, thermal/night vision), since Phase 1
already has three independent copies of "find nearest X" logic
(`FindNearestK9Vehicle` in client/vehicle.lua, `FindNearestLeashCandidate`
in client/radial.lua, and the K9-model-hash precompute pattern repeated in
three files) — Phase 2 should not add a fourth/fifth divergent copy of the
same shape of helper without at least flagging that as a possible shared
utility candidate._
