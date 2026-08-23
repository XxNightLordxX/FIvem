# Phase 2 Design Note — Scent Tracking & Blood Trail Tracking

Author: coder-architect (client-logic lens)
Date: 2026-08-23
Status: **SUPERSEDED-AND-REALIGNED.** This note originally proposed its own
event/callback contract and file split before product-manager's detailed
Phase 2 spec landed in `SPEC.md` §11 mid-session. It has been rewritten
from scratch to track §11 exactly rather than offer a competing design —
per direction, the goal now is **confirming and refining §11**, not
replacing it. Anywhere this note used to invent a name/shape
(`findNearestScentSource`/`findNearestBloodSource` as two callbacks, a
client-report event named `reportDamageLocation`, separate scent-only /
blood-only files) has been dropped in favor of §11's actual contract
(`findTrackableSource`, `relayDamageEvent`, one shared `client/tracking.lua`
+ `server/tracking.lua` pair covering scent/blood/gunpowder together).

Still **no `.lua` implementation exists or should be started from this
note** — this is a design/confirmation pass only, matching the standing
instruction not to write final code ahead of an already-shipped detailed
spec being fully absorbed by the team.

Scope: this note covers **Scent Tracking and Blood Trail Tracking**
specifically (SPEC.md §11's `ScentTracking`/`BloodTracking` features, plus
the `WaterTrackingDecay` modifier that applies to both). It cites
`GunpowderSniffing` only where it shares infrastructure (same file, same
callback, same log-and-prune pattern) — the acceptance criteria and
relay-event design for gunpowder itself belong to whoever picks up that
feature, not duplicated here.

---

## 1. Authoritative source: read SPEC.md §11 directly

The actual contract is already spec'd in detail and should not be
re-derived or second-guessed here:

- **§11.2** — `Config.Tracking.Scent` / `Config.Tracking.Blood` (maxRange,
  markerSpacing, searchCooldownMs, maxAgeSeconds for Blood) and
  `Config.WaterTrackingDecay` (sampleIntervalMeters, breaksTrail).
- **§11.3** — file plan: `client/tracking.lua` (new) owns the "Track Scent"
  / "Track Blood" (and "Track Gunpowder") radial self-actions, trail
  marker rendering, and water-crossing degrade logic; `server/tracking.lua`
  (new) owns the damage-event/weapon-fire relay log, its prune pass, and
  the `findTrackableSource` callback. Both scent and blood live in the
  **same** file pair as gunpowder — not split into per-type files, which
  is the one point this note's earlier draft got wrong.
- **§11.4 item 1** — `qbx_k9unit:server:findTrackableSource(trackType)` →
  `{ found, coords?, breaksAtWater }`, re-validates
  `Config.Features.<Type>` and `HasK9Access(source)`, resolves the
  **caller's own live server-side position** (never client-supplied),
  enforces `Config.Tracking.<Type>.searchCooldownMs` per caller.
- **§11.4 item 3** — `qbx_k9unit:server:relayDamageEvent()`, triggered by
  the victim's own client off `gameEventTriggered('CEventNetworkEntityDamage', ...)`,
  no meaningful payload — the server logs **the reporting client's own live
  coordinates**, resolved server-side via `GetEntityCoords(GetPlayerPed(source))`,
  never a client-claimed position.
- **§11.5** — full acceptance criteria for both features and the water
  modifier. **§11.6** — reality-check refinements, including the
  already-independently-confirmed note that `CEventNetworkEntityDamage` is
  a real, documented FiveM game event, but fires per-client, so the
  relay-to-server step is genuinely authored code, not something that
  exists for free.
- **§9 items 10, 11, 14** — the standing open questions that touch this
  feature pair specifically (relay-code effort, ox_inventory export names
  for scent-source detection, and whether tracking needs additional
  abuse-limits beyond the per-type cooldown). Not re-opened here; tracked
  there so correctness-overseer/team-leader have one running list.

Nothing below contradicts any of the above. What follows is this note's
value-add: client-logic-lens refinement of *how* `client/tracking.lua`
would actually implement §11's contract, using the same conventions
Phase 1's files already established, plus a couple of gaps §11 leaves
genuinely open that are worth flagging before implementation starts.

---

## 2. Client-side refinement (`client/tracking.lua`)

### 2.1 Session state — mirror `client/movement.lua`'s `leashState` pattern

A single local `trackingState` (not exposed directly, per the existing
file-to-file contract convention — only through exposed globals) should
hold `{ trackType, coords, breaksAtWater, startedAt, brokenByWater }`.
Exposed resource-global functions for `client/radial.lua` to call, per
§11.3's naming:

- `StartScentTrack()`
- `StartBloodTrack()`
- (`StartGunpowderTrack()` — not this note's scope, but shares the same
  shape)
- `StopTracking()` / `IsTracking() -> boolean`, for a manual-cancel item
  mirroring Attach/Detach Leash's context-sensitive single-item pattern —
  §11 doesn't explicitly spec a "Stop Tracking" affordance, so this is a
  refinement worth flagging: without one, a player who starts a trail
  they no longer want has no self-service way to make the markers stop
  rendering short of walking to the source or waiting out
  `searchCooldownMs` and re-triggering (which doesn't even clear the old
  render). Recommend adding a cancel path for the same "never leave a
  player stuck in a state with no free exit" reasoning §9 item 3b already
  established as a hard requirement for leash detach — lower stakes here
  (it's cosmetic, not a movement restriction), but the same principle.

Each `Start*Track()` implementation:
1. `CanShowK9UI()` re-check (cheap, local — same pattern every existing
   radial `onSelect` already uses), notify+deny on failure.
2. `lib.callback.await('qbx_k9unit:server:findTrackableSource', false, trackType)`.
3. If `found == false`, notify "nothing to track nearby" (or "on
   cooldown" — see §2.4 below on distinguishing the two) and don't start a
   session.
4. If `found == true`, set `trackingState` and let the shared
   trail-rendering thread (§2.2) pick it up — the thread reads
   `trackingState` fresh every iteration, so setting it is sufficient to
   "wake" rendering, exactly the comment already on `client/movement.lua`'s
   leash-attached handler ("simply setting it here is sufficient to wake
   the tighter-interval pulling behavior... no separate thread-start call
   needed").

### 2.2 Trail-rendering thread — reuse the leash thread's idle/active split

`client/movement.lua`'s leash pull-back thread already establishes the
exact pattern this should reuse: a single perpetual `CreateThread` that
sleeps long (its `LEASH_IDLE_TICK_MS`, 1000ms) while idle and switches to a
short tick (its `LEASH_TICK_MS`, 250ms) only while a session is active —
not a `Wait(0)` tight loop running unconditionally, and not a thread that
gets started/stopped per session (avoids any thread-lifecycle bookkeeping
bugs, mirrors the "just set the state, the thread notices" design already
proven out for leash). Flagging the exact tick rate for
`resource-performance-profiler` to weigh in on once this is real code
(`DrawMarker` itself needs to be called every frame it should render, per
its own native contract — same "must call every frame while active" note
`client/movement.lua`'s `AgilityBasicJump` `DisableControlAction` block
already documents for a different native with the same constraint — so
the *rendering* half of the tick may need a faster inner loop than the
*water-sampling*/*re-poll* half; these don't have to share one interval).

### 2.3 What actually renders

- **Breadcrumb markers**: a run of `DrawMarker` calls at points spaced
  `Config.Tracking.<Type>.markerSpacing` meters apart along the line from
  the K9's current position toward `trackingState.coords`. §11 doesn't
  specify whether the *entire* remaining trail renders at once or only a
  capped preview window near the player — this is a genuine, currently
  unresolved UX choice worth flagging rather than assuming either way:
  revealing the whole straight-line distance up front is simpler to
  implement and matches "a trail of markers toward the nearest source"
  read literally, but arguably gives away the exact answer immediately
  for a short-range search, undercutting the tracking fantasy. Recommend
  whoever picks this up confirm with product-manager/feature-ideation
  before committing to one, since it's a real behavioral fork like the
  ones §9 already tracks for other decisions, not a pure implementation
  detail.
- **Water-crossing sampling**: per §11.2's `Config.WaterTrackingDecay.sampleIntervalMeters`
  and §11.5's acceptance criteria, sample the rendered path at that
  interval for water presence. Implementation shape: for each sample point
  along the segment from the K9's position to `trackingState.coords`,
  compare terrain height at that XY against the water height at the same
  XY — the two-native combination (`GetGroundZFor_3dCoord` +
  `GetWaterHeight`/`GetWaterHeightNoWaves`) is the well-established pattern
  for testing an arbitrary point rather than a live entity's current
  position (a live-entity-only water check, like `IsEntityInWater`,
  isn't sufficient here since the segments being tested are usually points
  the player hasn't reached yet). **Not independently re-verified against
  current CitizenFX SDK/native docs this session** (native-api-assistant
  was reachable for §11.6's vision-native confirmation but not reachable
  when this note went looking for a water-native pass — flag for whoever
  implements this to get an explicit confirmation pass before shipping,
  same "confidence note, not asserted fact" treatment `server/certifications.lua`
  already gives its own unverified qbx_core export guesses).
- On `Config.WaterTrackingDecay.breaksTrail == true` (default) and a
  crossing detected: stop revealing markers past the crossing point, set
  `trackingState.brokenByWater = true`, notify the player, and require a
  fresh `Start*Track()` call once near the far bank (§11.5's stated
  behavior — a fresh `findTrackableSource` call naturally answers "am I
  close enough now," no separate re-acquire mechanic needed). On
  `breaksTrail == false`, render markers within/near water at reduced
  opacity instead of omitting them, per §11.5.

### 2.4 Cooldown UX

§11.4 item 1 says the server enforces `searchCooldownMs` and returns
`found = false` when rejected for any reason, with no `reason` field
listed in that callback's return shape (unlike `searchTarget`'s explicit
`reason` string in item 2). Worth flagging: without a distinguishing
field, the client can't tell "nothing nearby" apart from "you're on
cooldown" apart from "you don't have access" to phrase the right
notification — all three currently collapse to the same `found = false`.
Recommend either (a) accepting a single generic "can't track right now"
message for all three (simplest, matches the deliberately terse
`hasK9Access` boolean precedent), or (b) adding an optional `reason` field
to `findTrackableSource`'s return shape mirroring `searchTarget`'s, if
distinguishing them in the UI turns out to matter. Flagging as a small
open question for whoever finalizes `server/tracking.lua`, not deciding
it here.

### 2.5 Radial wiring (`client/radial.lua`)

Two new items under the existing "K9 Unit" submenu, following the exact
template every existing item already uses (per §11.3's row for this file):
`Config.Features.ScentTracking`/`Config.Features.BloodTracking` gate at
registration time, `CanShowK9UI()` re-check inside `onSelect`, a one-line
delegate into `client/tracking.lua`'s exposed global, `DenyNotify()` on
failure — no new logic pattern needed, this file's own header rule
("thin wiring only") already covers it.

---

## 3. Server-side refinement (`server/tracking.lua`)

From this note's client-logic lens, the two things most worth double-checking
once this file is written (both already implied by §11.4, restated here for
emphasis since they're the actual security-relevant parts of an otherwise
low-stakes feature):

1. **`findTrackableSource` must resolve position from `GetPlayerPed(source)`,
   never accept one as an argument.** The callback signature in §11.4 item 1
   only takes `trackType` — no coordinate parameter — which already
   forecloses a client-supplied-position mistake at the interface level.
   Worth calling out explicitly for coder-security's review anyway, since
   it would be an easy regression to "helpfully" add a coords parameter
   later for some other reason and silently reintroduce a client-trusted
   position.
2. **`relayDamageEvent` takes no payload and logs the reporting client's
   own resolved position** — same reasoning. This is the one place in this
   whole feature pair where a client asserts something about the world
   ("I just took damage") rather than merely querying it; per §11.4 item 3
   the *fact* of damage is trusted (a false report just plants a harmless
   phantom blood-trail location), but the *position* is never trusted from
   the client — the server always re-derives it from the reporting
   player's own live ped. This distinction (trusting "something happened"
   but never trusting "where") is the right shape for something this
   low-stakes, and is worth stating explicitly in that file's header
   comment once written, matching how `server/certifications.lua`'s header
   already explains *why* each check exists, not just *what* it is.

Both of the above are already what §11.4 specifies — nothing to change,
just flagging them as the two lines coder-security should look at first
when this file lands, per this task's own note that client code decisions
with real-world effect need independent server verification.

---

## 4. Native verification status

- **`CEventNetworkEntityDamage` via `gameEventTriggered`** — already
  independently confirmed in SPEC.md §11.6 as a real, documented FiveM
  game event carrying victim/attacker/weapon data, firing per-client to
  whichever clients have the entities involved streamed in. Nothing further
  to verify here.
- **`SetSeethrough`/`SetNightvision`** — confirmed in §11.6 for the vision
  features; not this note's scope, cited only for completeness.
- **`DrawMarker`** for breadcrumb rendering, and **`GetWaterHeight`/
  `GetWaterHeightNoWaves`/`GetGroundZFor_3dCoord`** for water-crossing
  sampling — both are long-standing, extremely well-established FiveM/GTA
  natives (matches the same class of "genuinely correct, high confidence,
  not independently re-verified against current docs this specific
  session" the rest of this codebase already flags rather than silently
  asserting as fact — e.g. `client/movement.lua`'s control-index comments).
  Sent to native-api-assistant for an explicit confirmation pass; not
  reachable this session (message queued, no response yet). **Do not skip
  that confirmation pass before writing final code** — cheap to do, and
  this codebase's own convention (§11.6's independent re-confirmations) is
  to actually get it rather than assume.
- **Optional "sniffing" self-animation** while a tracking session is
  active: not required by §11's acceptance criteria at all, but would
  mirror `client/movement.lua`'s `K9Sit()` precedent (breed-specific
  `WORLD_DOG_SITTING_*` scenarios, confirmed by native-api-assistant in
  that file's own header). If wanted, a `WORLD_DOG_*`-family "sniffing/
  searching" scenario would need the same confirmation pass `K9Sit()`
  already got — flagged as a nice-to-have, not scoped into this note's
  acceptance criteria since §11.5 doesn't call for it.

---

## 5. Summary of what's still genuinely open (beyond §9's existing list)

These are additions to, not replacements of, SPEC.md §9 items 10/11/14
(already tracked there):

1. **Full-trail-reveal vs. capped-preview-window rendering** (§2.3) — a
   real behavioral fork, not decided by §11's text either way.
2. **No self-service "Stop Tracking" affordance** currently specified
   (§2.1) — recommend adding one, flagged rather than assumed necessary.
3. **`findTrackableSource`'s `found = false` doesn't distinguish "nothing
   nearby" from "on cooldown" from "no access"** (§2.4) — small UX gap,
   easy one-line fix if wanted, not decided here.
4. **Whether an active tracking session should auto-cancel on mid-session
   loss of K9 access** (certification revocation, department change) —
   §4.4's leash precedent (`ForceDetachLeashForSource`) tears down an
   in-progress leash pairing immediately on revocation; §11 doesn't say
   whether a tracking session needs the same treatment. Given a tracking
   session grants no real capability (it's a client-cosmetic marker
   render, per §11.6's framing) and self-expires the moment the player
   next tries to re-poll or interact, this is much lower-stakes than
   leash's "real movement restriction that must not outlive access" case —
   but flagging it for the same reason §9 item 14 already flags
   tracking-specific abuse-limits as an open judgment call, not asserting
   either answer is obviously right.
5. **Water native confirmation pass (§4)** — outstanding with
   native-api-assistant, not yet closed out this session.
