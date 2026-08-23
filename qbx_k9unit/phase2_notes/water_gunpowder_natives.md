# Phase 2 native verification — Water Tracking & Gunpowder Residue Sniffing

## Addendum — cross-checked against SPEC.md §11 (real Phase 2 spec)

The task that kicked off this note described these two features generically;
SPEC.md §11 has since landed with the actual concrete design. Cross-checking
my independent native research (above/below) against §11's specifics:

1. **Water tracking is a cross-cutting trail modifier (`Config.WaterTrackingDecay`,
   §11.2/§11.5), not a standalone trackable type** — it periodically samples
   *whichever trail is currently being rendered* (scent/blood/gunpowder)
   every `Config.WaterTrackingDecay.sampleIntervalMeters` along the path, and
   either hard-breaks it or fades it near/in a water crossing. My natives
   findings in §1 below apply directly and favorably to this exact shape:
   sampling a fixed-step path for "is there water here" is precisely the use
   case `GetWaterHeightNoWaves` (frame-stable) is better suited to than
   `GetWaterHeight` (wave-jittered) — since this is a periodic *poll along a
   path*, not a one-off live check at the K9's current position, frame
   stability matters more here than it would for a single instantaneous
   check. **Recommend `GetWaterHeightNoWaves` specifically for this
   sampling loop**, not the plain `GetWaterHeight` §6.3's original wording
   named — the config comment currently says "`GetWaterHeight` / water-flag
   natives," which is directionally fine (it is a real, working native for
   this) but I'd tighten it to the no-waves variant given the periodic-poll
   shape confirmed in §11.2, to avoid two samples 2m apart along a calm
   shoreline occasionally disagreeing purely due to wave phase at the moment
   each sample happened to run.
2. **Gunpowder sniffing trigger is a debounced local `IsPedShooting(PlayerPedId())`
   false→true transition on every client watching its own ped** (§11.4 item
   4), not a generic "detect any nearby weapon-fire event" native/hook. This
   is confirmed correct and is in fact a *better* pattern than the generic
   "poll nearby peds" approach I described in §2 below: since each client
   only ever checks its own single, already-known ped handle
   (`PlayerPedId()`), there's no pool enumeration or radius scan needed at
   all — it's one cheap native call per client per tick, with the actual
   fan-out (every shooter's own client independently detects and relays its
   own shot) replacing what would otherwise be an expensive
   every-nearby-ped scan on any single observer. `IS_PED_SHOOTING` (verified
   in §2 below, hash `0x34616828CD07F1A1`) is exactly the right native for
   this — no changes needed to §11.4 item 4's design. This also sidesteps my
   earlier performance flag for resource-performance-profiler, since it's
   the "watch your own ped" pattern rather than the "scan nearby peds"
   pattern — worth noting that resolution explicitly since I'd raised that
   concern generically below before seeing §11.4's actual design.
3. **Thermal/night vision — §11.6's refinement matches my independent
   findings exactly, no discrepancy to flag.** §11.6 already corrects
   SPEC.md §7's original "`SetTimecycleModifier`/nightvision" wording to
   `SetSeethrough(true/false)` for thermal and `SetNightvision(true/false)`
   for night vision. My own independent lookup (§3 below, done before I saw
   §11.6, against `citizenfx/natives` source directly) landed on the exact
   same two natives, same hashes
   (`SET_SEETHROUGH` = `0x7E08924259E08CE0`,
   `SET_NIGHTVISION` = `0x18F621F7A5B1F85D` / alt `0xD1E5565F`), and the
   same conclusion that `SetTimecycleModifier` is a real but unrelated
   native (correctly reserved in §11 for the separate contraband
   screen-filter feature, not vision). Two independent verification passes
   agreeing is a good sign — I'm not aware of anything in §11.6 that needs
   correcting on this point. One thing worth double-checking empirically
   before shipping (not a documentation-level concern, so not something I
   can resolve from native docs alone): §11.6's claim that both natives are
   "toggle-and-forget (no per-frame maintenance thread needed)" matches the
   natives' `void SET_X(BOOL)` signatures (no third state, no re-assertion
   parameter documented), but if in practice either effect is observed to
   get silently cleared by some other resource/scene transition on a live
   server, that would be an empirical finding, not something the native
   signature itself would reveal.

Scope: verifies SPEC.md §2, §6.3, §8 native claims for coder-frontend before
design finalization. All natives below cross-checked against the canonical
`citizenfx/natives` documentation source (docs.fivem.net itself is blocked by
this session's egress policy, so `raw.githubusercontent.com/citizenfx/natives`
— the same source docs.fivem.net is generated from — was used directly).
No `.lua` code included per task instructions; this is native verification
only.

---

## 1. Water detection natives

All four of these are **confirmed real, client-side natives**, no
deprecation notices found on any of them.

### `GET_WATER_HEIGHT` (namespace `WATER`)
- Hashes: `0xF6829842C06AE524` / `0xD864E17C`
- Signature: `BOOL GET_WATER_HEIGHT(float x, float y, float z, float* height)`
- Returns `false` when the ground at that x/y is above water level (i.e. no
  water there); `true` plus the out-param `height` otherwise. In FiveM's
  Lua/JS native wrappers, the `float* height` out-param becomes a second
  Lua return value — call as `local found, waterZ = GetWaterHeight(x, y, z, 0.0)`
  rather than expecting a pointer.
- Result **includes wave motion** — per the doc, results can fluctuate
  frame-to-frame near wavy water, so don't sample once and cache forever if
  used for a "did the trail cross water at this exact point" one-shot check;
  a single sample offset by wave noise is usually fine for a trail-decay
  gate, just don't expect bit-for-bit determinism between two calls at the
  same coord on different frames.
- This is the correct native for the SPEC's `GetWaterHeight` reference in
  §6.3 — confirmed as-named, not a guess.

### `GET_WATER_HEIGHT_NO_WAVES` (namespace `WATER`)
- Hashes: `0x8EE6B53CE13A9794` / `0x262017F8`
- Signature: `BOOL GET_WATER_HEIGHT_NO_WAVES(float x, float y, float z, float* height)`
- Same shape as above but **ignores wave animation** — deterministic across
  frames. **Recommend this one over `GetWaterHeight` specifically for the
  water-tracking trail-decay check** (§6.3), since you want a stable
  yes/no "is there a water body between these two trail waypoints" answer,
  not one that flickers with wave phase.

### `IS_ENTITY_IN_WATER` (namespace `ENTITY`)
- Hash: `0xCFB0A0D8EDD145A3` (alt `0x4C3C2508`)
- Signature: `BOOL IS_ENTITY_IN_WATER(Entity entity)`
- Works on any entity (ped, vehicle, object). This is the closest match to
  the task's "is this ped currently in water" ask if you want a general
  in-water check without caring about swim state specifically.

### `IS_PED_SWIMMING` (namespace `PED`)
- Hash: `0x9DE327631295B4C2` (alt `0x7AB43DB8`)
- Signature: `BOOL IS_PED_SWIMMING(Ped ped)`
- Ped-specific, tighter than `IsEntityInWater` — true when the ped's
  animation/locomotion state is actually swimming (deep water), not just
  "standing in an inch of puddle." **Companion:** `IS_PED_SWIMMING_UNDER_WATER`
  (hash `0xC024869A53992F34` / alt `0x0E8D524F`), same signature, true only
  when fully submerged/underwater — probably not needed for a K9 trail-decay
  check (a K9 fully submerged is an edge case, not the "crossed the river"
  case), but noting it exists since it's adjacent.

### On `_WATER_OUT_OF_RANGE` / similar
No native by that name (or a close variant) exists in the canonical native
list. That name does not correspond to a real CFX/GTA native — treat it as
a red herring from the original task phrasing, not something to implement
against. The natives above (`GetWaterHeight`/`GetWaterHeightNoWaves` +
`IsEntityInWater`/`IsPedSwimming`) are the real, documented surface for
water detection; there is no separate "out of range" sentinel native.

### Recommendation for §6.3 water-tracking decay
Use `GetWaterHeightNoWaves` sampled along the trail path (e.g. at each
waypoint or via a fixed-step raycast-style walk between two trail points) as
the primary "does this segment cross a water body" signal, since it's
frame-stable. `IsPedSwimming`/`IsEntityInWater` are better suited to a
*live* "is the K9 currently swimming right now" check (e.g. to suppress
scent-trail rendering entirely while mid-swim) than to a path-crossing
predicate, since they only tell you about the K9's *current* position, not
an arbitrary point along a trail the K9 hasn't reached yet.

---

## 2. Weapon-fire / gunpowder-residue detection

**Bottom line up front: there is no clean, single native or event that
hands you "a nearby gun was just fired, here's the shooter and location."**
This needs to be assembled from a few lower-level, client-side-only
building blocks. `OnPedWeaponFire` is **not a real FiveM event name** —
confirmed via search of FiveM's own client-events/game-events docs and
forum discussion; a forum thread titled "On(Player/Ped)WeaponShot Event
[Server Side] — Platform Suggestions" is itself a *feature request* asking
Cfx to add exactly this, which is further confirmation no such built-in
event ships today. Do not build around that name.

### Option A — `IS_PED_SHOOTING` (namespace `PED`)
- Hash: `0x34616828CD07F1A1` (alt `0xE7C3405E`)
- Signature: `BOOL IS_PED_SHOOTING(Ped ped)`
- Per-ped, per-tick poll: true on the frame(s) the ped is actively firing.
  This is the standard community approach for "did this ped just shoot" —
  poll it against nearby peds each tick, and on a false→true transition,
  record `GetEntityCoords(ped)` (the shooter's own position — appropriate
  for gunpowder residue, since residue is at the discharge point, not the
  bullet's landing spot) and a timestamp (`GetGameTimer()`) as the
  discharge event.
- **Performance note (flagging for resource-performance-profiler):** this
  requires enumerating nearby peds and calling `IsPedShooting` on each,
  every tick, client-side. This should be scoped to peds within a limited
  radius of the K9 (matching the "configurable time window"/radius already
  in §6.3/§6.6) and run on a modest interval (e.g. every 100-250ms, not
  every frame) rather than a tight `Wait(0)` loop across the whole ped pool
  — worth a dedicated perf pass before this ships, not just a correctness
  check.
- Companion: `IS_PED_SHOOTING_IN_AREA` (hash `0x7E9DFE24AC1E58EF` / alt
  `0x741BF04F`), signature
  `BOOL IS_PED_SHOOTING_IN_AREA(Ped ped, float x1, float y1, float z1, float x2, float y2, float z2, BOOL p7, BOOL p8)`
  — same idea but scoped to a bounding box; the two trailing bools are
  undocumented in the source (`p7`/`p8`), so don't rely on their exact
  semantics without testing in-game first if this variant is used instead
  of the simpler per-ped form.

### Option B — `GET_PED_LAST_WEAPON_IMPACT_COORD` (namespace `WEAPON`)
- Hash: `0x6C4D0409BA1A2BC2` (alt `0x9B266079`)
- Signature: `BOOL GET_PED_LAST_WEAPON_IMPACT_COORD(Ped ped, Vector3* coords)`
- Gives the **bullet's impact point**, not the shooter's position. This is
  a different data point than "where was the gun discharged" — useful only
  if a later design wants "residue where the bullet hit," which is not
  what gunpowder residue sniffing conceptually models (gunpowder residue is
  on/near the shooter, from muzzle discharge, not at the target). **Don't
  substitute this for the shooter-position approach in Option A** — flagging
  explicitly since it's an easy mix-up (both are "weapon fire" adjacent
  natives with similar-sounding purposes).

### Option C — `gameEventTriggered` + `CEventGunShot` family
- FiveM's game-events reference lists a family of gun-related low-level
  game events fired through the generic `gameEventTriggered(name, args)`
  client event: `CEventGunAimedAt`, `CEventGunShot`,
  `CEventGunShotBulletImpact`, `CEventGunShotWhizzedBy`,
  `CEventFriendlyAimedAt`, plus a broader set of `CEventShocking*` reaction
  events peds/AI use to react to gunfire, explosions, etc.
- **Caveat, and the reason this isn't simply "the" answer:** FiveM's own
  docs describe this whole list as "largely undocumented," and the
  `gameEventTriggered` payload is generically `(string name, int[] args)`
  with no per-event schema published — decoding which `args[]` slot is a
  ped handle vs. a coordinate vs. a weapon hash for `CEventGunShot`
  specifically is not something confirmable from documentation alone; it
  would require empirical reverse-engineering (logging raw `args` in-game)
  rather than trusting a memorized index. I'm not confident enough in any
  specific args-index mapping to hand you one without fabricating it — if
  this route is preferred over Option A, budget time to log and inspect
  `args` live rather than coding against an assumed layout.
- This event is fired client-side only (it lives in FiveM's client-side
  `citizen-resources-gta` component) — same networking implication as
  Option A below.

### Networking implication (applies to both A and C)
Weapon-fire detection is inherently **client-observed only** — there is no
server-side native or event that independently confirms "a weapon was
fired near this location." Whichever option is used, the detecting
client (the K9's own client, or a nearby client) must `TriggerServerEvent`
the discharge coords/time to the server for anything server-authoritative
(e.g. feeding a `Config.Features.GunpowderSniffing`-gated search result).
That means a modified client could in principle spoof a fabricated
discharge event — worth flagging for coder-security's review alongside the
rest of §4's "never trust client-reported state" pattern, same shape as the
model/proximity checks already called out there, though the actual
mitigation design is outside this note's scope (native verification only).

### Recommendation for §6.3 gunpowder sniffing
Option A (`IsPedShooting` polling + `GetEntityCoords`/`GetGameTimer` on
transition, client-side, server-reported) is the one I'd build against —
it's a confirmed, documented native with clear semantics, versus Option C's
undocumented args layout. Keep the polling radius/interval tight per the
performance note above.

---

## 3. Re: SPEC.md §7 thermal/night vision claim — verified, with one precision correction

**Claim in §6.3/§7:** "Thermal vision and night vision use native
`SetTimecycleModifier`/nightvision natives only — no custom shader work."

**Verdict: holds up as fully native-only and zero-asset, but the natives
named are slightly off** — there are dedicated, self-contained toggle
natives for both effects; `SetTimecycleModifier` is not actually the
mechanism that drives either one, and doesn't need to be called at all for
a baseline implementation.

- `SET_NIGHTVISION` (namespace `GRAPHICS`, hash `0x18F621F7A5B1F85D` / alt
  `0xD1E5565F`), signature `void SET_NIGHTVISION(BOOL toggle)` — a single
  boolean toggle that turns the built-in green night-vision effect on/off
  for the calling client. Nothing else required.
- `SET_SEETHROUGH` (namespace `GRAPHICS`, hash `0x7E08924259E08CE0`),
  signature `void SET_SEETHROUGH(BOOL toggle)` — same shape, toggles the
  built-in heat-vision/thermal effect ("Toggles Heatvision on/off" per the
  doc). This is the actual thermal-vision native, not a timecycle modifier
  hack.
- `SET_TIMECYCLE_MODIFIER` (namespace `GRAPHICS`, hash
  `0x2C933ABF17A1DF41` / alt `0xA81F3638`), signature
  `void SET_TIMECYCLE_MODIFIER(char* modifierName)` — this is a real,
  separate native, but it loads an arbitrary named visual filter (e.g.
  `"V_FIB_IT3"`) from the game's built-in timecycle mod files. It's the
  correct native for §6.6's *contraband screen filter* (reusing an existing
  "drug effect" style modifier name), which is a distinct feature from
  night/thermal vision. It is **not required** for baseline night/thermal
  vision — `SetNightvision`/`SetSeethrough` are self-sufficient toggles.

**Net effect on the spec:** the underlying claim ("achievable purely with
existing natives, no custom shader/asset work") is correct and confirmed.
The one thing worth correcting before coder-frontend builds against it: the
implementation should call `SetNightvision`/`SetSeethrough` directly for
§6.3's night/thermal vision feature, and reserve `SetTimecycleModifier` for
the separate §6.6 contraband screen-filter feature — bundling them together
under one native name in the spec text was imprecise, not wrong about
feasibility.

---

## Sources
- [GetWaterHeight.md](https://github.com/citizenfx/natives/blob/master/WATER/GetWaterHeight.md)
- [GetWaterHeightNoWaves.md](https://github.com/citizenfx/natives/blob/master/WATER/GetWaterHeightNoWaves.md)
- [TestProbeAgainstWater.md](https://github.com/citizenfx/natives/blob/master/WATER/TestProbeAgainstWater.md)
- [IsEntityInWater.md](https://github.com/citizenfx/natives/blob/master/ENTITY/IsEntityInWater.md)
- [IsPedSwimming.md](https://github.com/citizenfx/natives/blob/master/PED/IsPedSwimming.md)
- [IsPedSwimmingUnderWater.md](https://github.com/citizenfx/natives/blob/master/PED/IsPedSwimmingUnderWater.md)
- [IsPedShooting.md](https://github.com/citizenfx/natives/blob/master/PED/IsPedShooting.md)
- [IsPedShootingInArea.md](https://github.com/citizenfx/natives/blob/master/PED/IsPedShootingInArea.md)
- [GetPedLastWeaponImpactCoord.md](https://github.com/citizenfx/natives/blob/master/WEAPON/GetPedLastWeaponImpactCoord.md)
- [game-events.md (citizenfx/fivem-docs)](https://github.com/citizenfx/fivem-docs/blob/master/content/docs/game-references/game-events.md)
- [gameEventTriggered.md (citizenfx/fivem-docs)](https://github.com/citizenfx/fivem-docs/blob/master/content/docs/scripting-reference/events/list/gameEventTriggered.md)
- [SetNightvision.md](https://github.com/citizenfx/natives/blob/master/GRAPHICS/SetNightvision.md)
- [SetSeethrough.md](https://github.com/citizenfx/natives/blob/master/GRAPHICS/SetSeethrough.md)
- [SetTimecycleModifier.md](https://github.com/citizenfx/natives/blob/master/GRAPHICS/SetTimecycleModifier.md)
- Forum thread confirming no built-in weapon-fire event exists:
  "On(Player/Ped)WeaponShot Event [Server Side] — Platform Suggestions",
  forum.cfx.re (found via search; corroborates `OnPedWeaponFire` is not a
  real event and is a requested-but-unshipped feature)

Note: docs.fivem.net, runtime.fivem.net, alloc8or.re, and fivemdocs.com are
all blocked by this session's egress policy, so verification above used
`raw.githubusercontent.com/citizenfx/natives` directly — the same upstream
source docs.fivem.net renders from — plus targeted WebSearch snippets for
cross-referencing. If a stricter single-source-of-truth citation is needed
later (e.g. for a compliance audit), someone with docs.fivem.net access
should spot-check the hashes above match.
