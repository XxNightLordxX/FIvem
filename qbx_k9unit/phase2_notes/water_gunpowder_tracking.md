# Phase 2 design note: Water Tracking & Gunpowder Residue Sniffing

Status: **v2 — rewritten against the now-landed detailed spec.** My original
draft of this note was written before product-manager's Phase 2 detail pass
existed; that pass has since landed as **SPEC.md §11** (dated 2026-08-23),
which resolves almost everything this note originally had to guess at. This
version replaces the earlier draft in full rather than patching around it,
since the landed spec changes the shape of both features materially (see
§0.1 below for exactly what changed). Treat SPEC.md §11 as authoritative;
this note exists to (a) confirm my read of it is correct from a
client-script-logic lens, (b) add the client-side implementation detail §11
deliberately leaves to "whoever implements it" (marker rendering approach,
sampling geometry, thread-gating), and (c) carry forward the handful of
things §11 itself still flags as unresolved. **No `.lua` is included** —
illustrative event/native names below describe an already-designed contract
(§11.4), not a new proposal, but this is still a design note, not
implementation.

Covers: `Config.Features.WaterTrackingDecay` and
`Config.Features.GunpowderSniffing`, per SPEC.md §11.2–§11.6.

Author: coder-frontend (client-side script logic lens). Cross-checked
against Phase 1's actual shipped files for convention (see §4).

---

## 0. What changed from my first draft, and why

### 0.1 Corrections to the original task framing

The task that started this note hypothesized two things that the **landed
spec explicitly does not do**:

1. **"Water tracking" is not a standalone trackable type with its own
   search command.** §11.1 and §11.2 are explicit: it's a *modifier*
   (`Config.WaterTrackingDecay`) applied by `client/tracking.lua` while
   rendering **any** currently-active trail (scent, blood, *or* gunpowder),
   not a fourth parallel tracking type with its own `maxRange`/
   `searchCooldownMs`/radial item. My original draft treated it as
   effectively its own feature with its own reacquisition flow — that
   framing is wrong; superseded below in §1.
2. **Gunpowder sniffing is not an `ox_target` check on a specific suspect
   ped.** My original draft assumed this (per the task's own stated
   hypothesis) by analogy to "Search Vehicle/Person." The landed spec
   (§11.3, §11.4 item 1, §11.5) instead makes gunpowder a **third
   trackable type alongside scent and blood** — a self-initiated "Track
   Gunpowder" radial action that finds the *nearest recently-logged
   weapon-fire location* within range and renders a trail toward it,
   using the exact same `findTrackableSource` callback shape as scent and
   blood. "Search Vehicle/Person" (`Config.Features.SearchZones`) is a
   **wholly separate feature**: it checks a target's *current, live*
   `ox_inventory` contents for contraband items (which happens to
   optionally include a weapon item in the placeholder
   `Config.SearchContrabandItems` list), not a *historical, time-windowed
   event log* the way gunpowder residue is. Different data source
   (live inventory vs. logged past event), different trust model, and per
   §11.3's own file-split rationale, different files
   (`client/search.lua`/`server/search.lua` vs.
   `client/tracking.lua`/`server/tracking.lua`). Superseded below in §2.

Both corrections are recorded here rather than silently dropped, since the
task's own framing explicitly asked me to figure out "whether" the
ox_target-on-suspect model applied — the answer, now that the real spec
exists, is no, and it's worth being explicit about why rather than just
quietly building the different thing.

### 0.2 Native-verification status (unchanged limitation)

I still could not reach native-api-assistant this session (no live agent by
that name was reachable to route the question to). §11.6 already does some
of this verification work itself (e.g. confirming `SetSeethrough`/
`SetNightvision` for vision, and being explicit that gunpowder/blood
tracking need "genuinely authored... relay code, not something that already
exists for free"), but it does **not** independently re-verify
`GetWaterHeight`'s exact success/failure semantics on dry land, or
`IsPedShooting`'s exact behavior across a sustained automatic-weapon burst
(does it stay `true` continuously, or toggle per round?) — both matter for
getting the sampling/debounce logic right and remain open per §3 below.
Whoever implements `client/tracking.lua` should get these confirmed before
writing the real sampling/debounce code, not assume the names above are a
complete enough answer on their own.

---

## 1. Water Tracking (`Config.WaterTrackingDecay`) — cross-cutting trail modifier

### 1.1 What it is (per §11.1/§11.2/§11.3, restated for clarity)

Not a `Config.Features` flag with its own tracking type — it's a rendering
modifier `client/tracking.lua` applies while drawing *any* active trail
(scent, blood, or gunpowder). It has no `maxRange`/`searchCooldownMs`/radial
item of its own for exactly that reason; it only has
`sampleIntervalMeters` (2.0m default) and `breaksTrail` (true/false,
defaults `true`). `Config.Features.WaterTrackingDecay` is the toggle that
turns the modifier itself on/off — with it `false`, every trail type
renders as a plain straight line with no water-aware behavior at all
(§11.5's explicit acceptance bullet for this), confirming it really is a
strict layer on top of the other three, not a prerequisite for any of them
(§11.1 sub-phase 2f: it must land *after* at least one of scent/blood/
gunpowder already renders a trail, since there's nothing to degrade until
then).

### 1.2 What the trail geometry actually is, and where sampling happens

`findTrackableSource` (§11.4 item 1) returns a single resolved coordinate
(`coords: vector3`), not a waypoint list. Per §11.5's scent-tracking
acceptance bullet ("renders a sequence of trail markers spaced
`markerSpacing` meters apart, **from the K9's current position** toward the
resolved source coordinate"), the trail is a straight line recomputed live
from the K9's *current* position toward that fixed source coordinate — not
a captured, one-time path snapshot. That has two direct implications for
water sampling:

- The line's start point moves every tick as the K9 walks; the line's end
  point (the source coordinate) is fixed for the lifetime of that
  particular resolved source. Sampling for water should therefore run
  against the **current** live line, not a path frozen at the moment
  "Track \<Type\>" was triggered — a K9 that walks around an obstacle
  changes which points along the (recomputed) line need re-checking.
- Sampling points: start at the K9's live position, step toward the source
  coordinate in `Config.WaterTrackingDecay.sampleIntervalMeters` increments,
  test each stepped point for water via `GetWaterHeight`/water-flag natives
  (exact native TBD-confirmed, §0.2), stop at the first hit (or at the
  source coordinate if none). This is a straightforward per-tick geometric
  walk along a 2D segment, not pathfinding — consistent with §11 not
  mentioning any navmesh/pathfinding native anywhere in this feature's
  description.
- Note the spec's own acceptance bullet for `breaksAtWater` in the callback
  response: it's explicitly "informational only... this flag just tells it
  whether the config wants a hard break or a soft fade" (§11.4 item 1).
  Since `config.lua` is a `shared_script` (per `fxmanifest.lua`, unchanged
  by Phase 2's additions), the client already has direct access to
  `Config.WaterTrackingDecay.breaksTrail` without needing the server to
  echo it back — this field in the response shape is presumably there for
  future-proofing (e.g. a later per-department or per-trail-type override)
  rather than because the client couldn't otherwise know it. Not something
  to "fix" — just worth noting for whoever implements
  `client/tracking.lua` so they don't wonder why a locally-readable config
  value is also being sent over the wire.

### 1.3 Break vs. fade behavior (§11.5's acceptance bullets, restated with rendering detail)

- **`breaksTrail = true` (default):** rendering stops at the first sampled
  water point along the live line. No further markers render past that
  point regardless of how much closer to the source the K9 walks — this is
  a rendering-only decision (the resolved source coordinate the client
  already holds doesn't change), so "the previous trail does not silently
  resume once the player crosses" per §11.5 simply means: don't recompute
  markers past a detected crossing on this same resolved-source result: a
  **fresh** `findTrackableSource` call (i.e. a new "Track \<Type\>" radial
  trigger, subject to that type's `searchCooldownMs`) is required to obtain
  a new result and resume rendering — most likely the *same* source
  coordinate will be resolved again from the far-bank position (nothing
  server-side is water-aware; §11.4 item 1 is explicit that
  `breaksAtWater` is informational only, so the server's nearest-match
  logic doesn't itself avoid or re-route around water), at which point the
  line from the new (far-bank) K9 position to that same source coordinate
  is sampled fresh — and can legitimately break again if it *also* crosses
  water, with no special-casing needed for a second crossing.
- **`breaksTrail = false`:** markers within/near the detected water render
  at reduced opacity instead of being omitted, and rendering continues past
  the crossing toward the source normally. This only affects a
  marker-drawing parameter (alpha), not the sampling logic above — the same
  per-tick water-presence check runs either way, it's just a
  render-decision *how* to draw a marker once a water point is found,
  not whether to keep computing further markers.

### 1.4 Threading / performance

Per the project's established loop-gating convention (Phase 1's
`AgilityBasicJump` thread only exists/runs tight when actually relevant;
the leash pull-back thread idles at 1000ms when not leashed), the
water-sampling pass should only run while `client/tracking.lua` actually
has an active trail being rendered for the local player — not as an
always-on background scan. Worth a resource-performance-profiler pass once
real numbers exist for how many sample points a typical trail generates at
the default 2.0m interval over a `maxRange` of up to 40m (up to ~20 sample
points per trail-render tick in the worst case) — likely fine at a
few-times-per-second render/re-sample rate rather than every frame, but
that's a tuning call for implementation + profiling, not asserted here.

---

## 2. Gunpowder Residue Sniffing (`Config.Features.GunpowderSniffing`) — a tracking type, not a target check

### 2.1 End-to-end flow (per §11.3/§11.4/§11.5)

1. **Capture (client, per shooter):** while `Config.Features.GunpowderSniffing`
   is enabled, each client polls its own `IsPedShooting(PlayerPedId())`
   (native name per §11.4 item 4/§11.6; exact per-burst semantics
   unconfirmed, §0.2) and detects a debounced `false → true` transition.
   On that transition, it fires `qbx_k9unit:server:relayWeaponFire()` with
   no meaningful payload — the server resolves the reporting client's own
   live position itself (`GetEntityCoords(GetPlayerPed(source))`), never a
   client-supplied coordinate, mirroring the already-shipped `relayBark`
   pattern exactly.
2. **Logging (server, `server/tracking.lua`):** appends `{ coords,
   timestamp }` (keyed by shooter identity) to an in-memory, per-type
   rolling log, subject to its own **tight, dedicated rate limit** — §11.4
   item 4 is explicit this must be separate from
   `Config.Tracking.Gunpowder.searchCooldownMs` (that's a *query*-side
   cooldown on how often a K9 can re-run "Track Gunpowder"; the logging
   cooldown is about how often a single shooter's fire events get recorded
   at all, independent of whether anyone is currently tracking). No
   specific numeric default is given in §11.2/§11.4 for this logging
   cooldown — flagged in §3 below as still open.
3. **Pruning:** entries older than `Config.Tracking.Gunpowder.maxAgeSeconds`
   (120s default — deliberately shorter than blood's 300s, "residue is
   time-sensitive" per the config comment) are dropped, per §11.5's
   explicit "never returned as a valid source" acceptance bullet.
4. **Query (server, `findTrackableSource('gunpowder')`):** re-validates
   `Config.Features.GunpowderSniffing` and `HasK9Access(source)`
   server-side regardless of client UI state (identical posture to every
   other gated action in this resource), resolves the caller's own live
   position, and returns the nearest still-fresh logged fire location
   within `Config.Tracking.Gunpowder.maxRange` — same shape, same
   cooldown mechanism (`Config.Tracking.Gunpowder.searchCooldownMs`), as
   scent and blood.
5. **Render (client, `client/tracking.lua`):** identical trail-marker
   rendering to scent/blood (§1.2 above), including the water-crossing
   modifier from §1 applying equally to a gunpowder trail — §11.2's own
   comment on `Config.WaterTrackingDecay` explicitly lists gunpowder among
   the trail types it applies to.

### 2.2 What this means for "who fired," identity, and false positives

Because the log is keyed by shooter identity and read by *proximity to the
searching K9's own position* (not by "which suspect is standing right in
front of me"), gunpowder sniffing as spec'd answers "where was the nearest
recent gunfire" — it does **not** currently answer "did *this specific*
ped in front of me fire recently," which is what the task's original
ox_target hypothesis would have supported. If a later spec pass wants a
per-suspect "does this particular person have gunpowder residue on them"
check (closer to a real forensic gunpowder-residue test), that's a
different feature shape than what's landed in §11 and would need its own
spec pass — not something to silently build in addition to what's
specified here. Flagging this distinction explicitly so a future
implementer doesn't conflate "nearest gunfire location" (what's spec'd)
with "did this suspect shoot" (what the task originally guessed at, not
what shipped in §11).

### 2.3 Rate-limit design note (client lens)

The debounce itself (detecting the `false → true` transition rather than
firing every frame `IsPedShooting` is true) already avoids the worst-case
"fires every frame during a sustained burst" flood — but depending on
`IsPedShooting`'s actual per-round vs. per-burst semantics (§0.2, still
unconfirmed), a weapon with a very high semi-auto fire rate could still
generate many debounced transitions in a short window if the native
toggles per shot rather than staying `true` throughout a held-trigger
burst. This is exactly why §11.4 item 4 calls for a **separate, tight**
server-side rate limit on the logging event itself, independent of the
debounce — the debounce reduces the naive worst case, but shouldn't be
assumed sufficient on its own without confirming the native's real
behavior first.

---

## 3. Still-open items (not resolved by SPEC.md §11, not guessed at here)

1. **Exact `GetWaterHeight` semantics on dry land** (§0.2) — needed to get
   the water-presence test right without false positives/negatives;
   defer to native-api-assistant once reachable, per §11.6's own pattern
   of flagging rather than guessing at unverified natives.
2. **Exact `IsPedShooting` semantics across a sustained automatic-weapon
   burst** (§0.2, §2.3) — affects whether the debounce alone is enough or
   whether the dedicated rate limit needs to be more conservative than a
   simple per-shooter cooldown.
3. **Numeric default for the `relayWeaponFire` logging rate limit**
   (§11.4 item 4 mandates that it exist and be separate from
   `Config.Tracking.Gunpowder.searchCooldownMs`, but gives no default
   value) — needs a config field and a placeholder default from whoever
   implements `server/tracking.lua`, likely alongside the same
   economy-balance-style review other Phase 2/4 placeholder numbers
   already get flagged for elsewhere in this spec.
4. **Marker rendering native choice** — §11 doesn't specify whether trail
   markers are drawn as in-world `DrawMarker` rings (my lean, given the
   spec calls them "checkpoints" the player physically walks a path
   toward, and no existing Phase 1 file uses minimap blips for anything)
   or minimap blips (`AddBlipForCoord`), or both. Not specified in §11.3/
   §11.4/§11.5 at all — an implementation decision for whoever writes
   `client/tracking.lua`, not decided here since it doesn't affect any
   contract shape or trust boundary either way.
5. **Sampling/render tick rate for the water-crossing pass** (§1.4) — left
   to implementation + a resource-performance-profiler pass once real
   trail-length numbers exist.

---

## 4. Conventions carried over from Phase 1 (unchanged from my first draft)

- Every gated action re-verifies server-side regardless of what the client
  showed/claims — `findTrackableSource` and `relayWeaponFire` both follow
  this already per §11.4's own wording, consistent with §4.3's standing
  security posture.
- Ephemeral, session-scoped server state (the gunpowder/blood event logs
  in `server/tracking.lua`) should be a plain in-memory Lua table, not a
  DB table — §11.3 already says this explicitly, mirroring
  `server/main.lua`'s `LeashPairs` precedent, and flags it for db-schema
  to confirm rather than asserting it unilaterally.
- `ox_lib`'s `lib.notify` remains the established player-feedback channel;
  no new notification system should be introduced for either feature.
- Every native/event name should get the same inline confidence-note
  treatment `client/movement.lua` and `server/certifications.lua` already
  use in Phase 1 — especially given §0.2's still-unresolved verification
  gaps here.
- File ownership for what this note covers: `client/tracking.lua` (new,
  per §11.3) owns both the water-crossing modifier and the gunpowder
  trail's client-side capture/render logic; `server/tracking.lua` (new,
  per §11.3) owns the weapon-fire event log, pruning, and the
  `findTrackableSource` callback. This note is scoped to informing
  `client/tracking.lua`'s implementation specifically (my lens); the
  server-side contract is already fully specified in §11.4 and doesn't
  need re-deriving here.
