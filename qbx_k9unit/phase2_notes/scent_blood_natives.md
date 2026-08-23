# Phase 2 native groundwork — Scent Tracking / Blood Trail Tracking (SPEC.md §2, §6.3, §8, §11)

Author: native-api-specialist (this pass). Research-only — no `.lua` written.

**UPDATE:** product-manager's detailed Phase 2 design landed in SPEC.md §11
while this note was being written. §11.4/§11.6 already specify a concrete
mechanism for blood tracking — not the generic "some way to detect damage"
sketched in §2 below. §0 (immediately below) verifies that concrete design
directly. Sections 1–3 further down are the earlier, more general research
pass and are still accurate/useful background (trail-rendering natives,
water-crossing natives) but §2 in particular should be read as superseded by
§0 for the blood-trail mechanism specifically.

---

## 0. Verification of SPEC.md §11.4 item 3 / §11.6's actual blood-tracking design

**The design's load-bearing assumption is CORRECT — `gameEventTriggered` with
the event name `'CEventNetworkEntityDamage'`, filtered client-side to "am I
the victim," relayed via a payload-less `TriggerServerEvent`, is a real and
commonly-used pattern.** Verified this pass against two independent sources
(a Cfx forum thread on interpreting game events, and citizenfx/fivem GitHub
issue #2779, both fetched directly this session — not memory-only):

```lua
-- client-side, confirmed real pattern
AddEventHandler('gameEventTriggered', function(eventName, data)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    local victim = tonumber(data[1])
    if victim ~= PlayerPedId() then return end -- confirmed pattern for
        -- "local player is the victim" per §11.4 item 3's exact filter
    TriggerServerEvent('qbx_k9unit:server:relayDamageEvent')
end)
```

Point-by-point against §11.4 item 3 and §11.6's "Blood trail" bullet:

- **`gameEventTriggered` exists, fires `(eventName: string, args: table)`,
  and is client-only** (no server-side equivalent — the server process runs
  no game-event simulation at all). This is well-established FiveM
  architecture and is consistent with every source found this session;
  §11.6's own text already states this correctly ("fires locally,
  per-client... not automatically visible server-side") — confirmed, not
  contradicted, by this pass's research.
- **`CEventNetworkEntityDamage` is a real, correctly-spelled game event
  name.** Confirmed as a real, actively-discussed event across forum threads
  and two separate citizenfx/fivem GitHub issues (#2779, #3692) found this
  session — not a fabricated or misremembered name.
- **`data[1]` = victim entity handle is confirmed** (corroborated across
  multiple independent sources this session, including the two GitHub
  issues). This is exactly the field §11.4 item 3's design needs to filter
  on "local player is the victim" via `victim == PlayerPedId()`. The design
  correctly avoids needing `data[2]` (attacker) or the less-certain indices
  — it only needs the one well-corroborated field, which is a good, safe
  choice.
- **The "no meaningful payload, server reads the reporting client's own live
  coordinates" design (§11.4 item 3) is the right call and matches this
  resource's own established pattern** (identical in shape to `relayBark`'s
  "resolve the sender's own ped, don't trust a claimed netId/coordinate,"
  and to `certifications.lua`'s `GetEntityModel(GetPlayerPed(targetServerId))`
  live-read approach). `GetPlayerPed(source)` and `GetEntityCoords(ped)` are
  both real, stable, server-side-callable natives for this purpose — no
  concerns here.

**Two caveats worth flagging back to the design, neither of which breaks the
approach, both worth a code comment when `server/tracking.lua`/the client
handler get written:**

1. **`CEventNetworkEntityDamage` is confirmed (via citizenfx/fivem issue
   #3692, fetched this session) to NOT fire for script-applied damage** —
   e.g. a call to `ApplyDamageToPed` from some other resource (a custom
   medical/combat system, an admin tool, etc.) does not trigger this event,
   only organic gameplay damage (real weapon hits, falls, vehicle impacts,
   melee) does. If the target server's combat/medical resources apply
   damage programmatically rather than through native weapon-fire/collision
   paths, those hits will silently never produce a blood-trail source. Not
   a design flaw — just a real gap worth one sentence in `server/tracking.lua`'s
   header so a future "why didn't blood tracking pick this up" bug report
   isn't mysterious.
2. **Build-specific reliability bugs have been reported against this exact
   event** (citizenfx/fivem issue #2779, fetched this session, describes a
   build where fall damage either fails to fire the event at all or fires it
   with a misattributed weapon hash on a subsequent hit). This affects
   `data[7]` (weapon hash), not `data[1]` (victim), so it shouldn't corrupt
   *which* damage events get logged for blood-trail purposes on a current
   FXServer build — but it's a documented case of this event's data being
   occasionally unreliable, which supports §11.4/§11.6's own already-cautious
   framing (treat as "genuinely native-supported, not zero-effort/perfectly
   reliable").

**Adjacent check, since §11.6 pairs gunpowder sniffing with the same
sub-phase (2e) and cites `IsPedShooting`:** `IsPedShooting(Ped ped)` →
`BOOL` is a real, long-standing, stable native (client-side, well-established
FiveM knowledge, consistent with every source touching on it this session)
— the false→true debounce-and-relay pattern described in §11.4 item 4 is
sound and uses no native I have any doubt about. I did not find anything
suggesting `IsPedShooting` has reliability caveats comparable to the damage
event above.

**Bottom line for coder-frontend: ship §11.4 item 3 / §11.6's design as
written — the native/event assumptions underneath it hold up.** No
correction needed to the event name, the handler pattern, or the
no-payload/server-reads-own-position shape. The two caveats above are
"document this gap," not "the design is wrong."

---

Docs access note: `docs.fivem.net` and its known mirrors (`docs-backend.fivem.net`,
`fivemdocs.com`) are all blocked by this environment's egress proxy, and the
raw native-decls source on GitHub only covers CFX-added natives (not the
core R* natives below, which live in a different, non-fetchable DB). Every
native below is either (a) cross-checked against multiple independent
secondary sources (GitHub native-wrapper libraries, cfx forum threads
quoting the real doc text, GitHub issues from citizenfx/fivem discussing
the native's real behavior) where noted, or (b) flagged explicitly as
"well-established FiveM knowledge, not doc-verified this session" where no
independent source could be reached. Nothing below is invented from a single
unverified memory — where I could not cross-check, I say so rather than
present it as confirmed.

---

## 1. Breadcrumb-style trail toward an undiscovered location

**Bottom line: there is no native that does this. It has to be built as
client-side custom rendering, not a single native call.**

### `DRAW_MARKER` — the actual building block for this
```
void DRAW_MARKER(int type, float posX, float posY, float posZ,
    float dirX, float dirY, float dirZ, float rotX, float rotY, float rotZ,
    float scaleX, float scaleY, float scaleZ,
    int red, int green, int blue, int alpha,
    BOOL bobUpAndDown, BOOL faceCamera, int rotationOrder, BOOL rotate,
    char* textureDict, char* textureName, BOOL drawOnEnts)
```
- **Client-only.** Must be called every frame (inside a `Citizen.Wait(0)`
  loop) for the marker to persist — it's a "draw this one frame" call, not
  "place a persistent world marker." This is standard, stable, not
  deprecated.
- Fits the intended use directly: to render a "trail," the design would
  compute a sequence of waypoints along a path (straight-line interpolation
  or a `GET_SAFE_COORD_FOR_PED`-style walkable-path approximation) between
  the K9's current position and the scent/blood source, then `DrawMarker`
  each waypoint the player hasn't yet reached — classic "breadcrumb" pattern
  used by drug-delivery / treasure-hunt style FiveM scripts. Reveal-as-you-go
  is just "only draw markers within N meters of the player's current
  position along the path," recomputed each tick — there's no native concept
  of "hidden until discovered," it's purely a client-side draw-or-don't-draw
  decision per frame.
- Performance note (for resource-performance-profiler, since this runs in a
  tight per-frame loop): drawing many `DrawMarker` calls per frame is
  cheap individually but the loop itself must not run at `Wait(0)` for its
  *own* bookkeeping (recomputing the path, checking distance-to-next-point)
  if that logic is non-trivial — separate "how often do we recompute the
  path" from "how often do we draw the current frame's markers." Worth a
  proximity gate (e.g. > `Config.XPTiers[].scentRange` from source, don't
  render/compute at all) rather than always running once ScentTracking is
  toggled on.

### `SET_BLIP_ROUTE(Blip blip, BOOL enabled)` — confirmed real, but wrong shape for this feature
- Cross-checked (search corroborates the two-arg `Blip, BOOL` shape, matching
  the CFX doc convention for this native — not fetched from the live page
  but consistent across multiple independent citations).
- This toggles the built-in GPS route line to a blip on the minimap/map —
  it draws the **entire path immediately** (a static line, either straight
  or road-routed depending on blip type), not a progressive/undiscovered
  trail. **This does not fit the "hasn't discovered yet" breadcrumb
  requirement** — using it would reveal the whole route the instant the
  blip is created, defeating the intended "track it out, don't just see it"
  gameplay. Flagging this explicitly because it's the native most likely to
  get reached for by mistake (it "sounds like" what's wanted) — don't use
  it for scent/blood trails. It's still the right tool if a later feature
  ever wants a plain "GPS route to a known objective" (different from a
  discoverable trail).

### `ADD_BLIP_FOR_COORD` / `SET_NEW_WAYPOINT` — supporting natives, not the core mechanic
- `Blip ADD_BLIP_FOR_COORD(float x, float y, float z)` — client-side, creates
  a normal map blip at a coordinate. Well-established, stable. Useful only
  as "show a blip at the *next* undiscovered breadcrumb point," not as the
  trail-rendering mechanism itself (that's `DrawMarker`, which draws in the
  3D world, not just on the map).
- `SET_NEW_WAYPOINT(float x, float y)` sets the player's GPS waypoint (the
  yellow map marker) — again a single-destination tool, not a multi-point
  trail. Could be used for "set waypoint to final scent source once fully
  tracked," as a distinct, separate action from the in-world breadcrumb
  markers, if the design wants that as a capstone once the trail's fully
  walked.

**Recommendation to coder-frontend:** design the trail as client-side
`DrawMarker` calls along a precomputed point list, gated by distance-
travelled/proximity, refreshed by a moderate-interval thread (not `Wait(0)`
for the compute step) — this is squarely within existing, unremarkable
FiveM native capability, just not a single native call. No native or ox_lib
export does "reveal a scent trail" as a built-in concept.

---

## 2. Damage-event detection for blood trail source data

**Bottom line: there is no native that stores "this ped took damage at this
location at this time" as queryable history. This needs custom event
tracking hooked into `gameEventTriggered`, matching the pattern this repo
already uses elsewhere (custom event capture, not a native query).**

### `gameEventTriggered` + `CEventNetworkEntityDamage` — the actual mechanism
- **Client-side only.** This is a well-established, hard constraint: FiveM's
  server process does not run game-event simulation at all (no game world on
  the server), so `gameEventTriggered` has no server-side equivalent —
  cross-checked against the CFX forum/GitHub issue discussion threads found
  this session (citizenfx/fivem issues #2779 and #3692 discuss exactly this
  event's client-only firing behavior and known edge cases where it doesn't
  fire reliably in OneSync — worth being aware the event is not 100%
  reliable even client-side, per those bug reports).
- Argument layout for the `CEventNetworkEntityDamage` game event, per
  cross-checked community documentation (not the primary CFX doc page,
  which was unreachable this session — treat this order as reasonably
  well-established but not primary-source-confirmed):
  ```lua
  AddEventHandler('gameEventTriggered', function(eventName, args)
      if eventName ~= 'CEventNetworkEntityDamage' then return end
      local victim      = tonumber(args[1])   -- entity handle, victim
      local attacker    = tonumber(args[2])   -- entity handle, attacker (or the same as victim/-1 for non-ped sources)
      -- args[3] historically reported as "weapon loadout index" / unclear
      local victimDied  = tonumber(args[4]) == 1
      -- args[5]/[6] historically reported as unclear/internal
      local weaponHash  = tonumber(args[7])
  end)
  ```
  **Flagging directly:** I could not independently verify args[3], [5], [6]
  against a primary source this session — only [1], [2], [4], [7] are
  corroborated across multiple independent secondary sources. Do not build
  logic that depends on the unverified indices without re-confirming against
  a live doc page once egress access is available, or against
  `GetPedLastDamageBone`/`GetPedSourceOfDamage` as alternate confirmations.
- Since this only fires client-side, "location" isn't part of the event
  payload at all — the design has to call `GetEntityCoords(victim)` itself,
  in the handler, at the moment the event fires, and persist that
  (victim, coords, timestamp, optionally weaponHash) tuple into whatever
  data store backs the blood trail (client-side table if scent trails stay
  fully client-local per SPEC §6.3's "client-side-only markers" language, or
  relayed to the server via a custom event if the design wants trail sources
  to persist/be shared across clients — that's a design decision for
  coder-frontend, not something a native resolves for you).

### Supporting natives (confirm state, don't give history)
- `GetPedLastDamageBone(Ped ped)` → `BOOL, int` (found flag + bone index).
  **Client-side.** Confirmed real and commonly paired with
  `CEventNetworkEntityDamage` in existing community code, but per multiple
  forum threads found this session it's described as "isn't perfect" /
  known to sometimes return stale or wrong bone data — don't treat it as
  authoritative if precision matters, just as a nice-to-have detail
  (e.g. flavor text on which limb was hit) rather than the core blood-trail
  mechanism.
- `HAS_ENTITY_BEEN_DAMAGED_BY_ANY_PED(Entity entity)` /
  `HAS_ENTITY_BEEN_DAMAGED_BY_ANY_VEHICLE(Entity entity)` /
  `HAS_ENTITY_BEEN_DAMAGED_BY_WEAPON(Entity entity, Hash weaponHash, int weaponType)`
  — these are one-shot "has this happened at all since last
  `CLEAR_ENTITY_LAST_DAMAGE_ENTITY`/`RESET_ENTITY_LAST_DAMAGE`-style call"
  booleans. They tell you **whether**, not **where** or **when** — no
  coordinate or timestamp is returned. Not sufficient alone for a trail
  (which needs a location per damage event, not just a sticky flag); could
  supplement the `gameEventTriggered` approach as a redundant "did I miss an
  event" check but shouldn't replace it.
- **No native equivalent of `GetPedSourceOfDamage` returning a coordinate
  exists that I could confirm.** Search only surfaced discussion of
  `GET_PED_SOURCE_OF_DEATH` (returns the *killer entity handle*, not a
  location, and only applies once the ped has actually died — not useful
  for a non-lethal "wounded, bleeding, still moving" blood trail case,
  which is presumably the more common blood-trail scenario). Do not assume
  a "get damage location" native exists — it doesn't; the coordinate has to
  be captured live by your own handler at the moment of the event, as above.

**Design implication to flag for coder-frontend explicitly:** because the
location capture is inherently client-observed (there's no server-side
damage-location native or event), if blood-trail data needs to be
server-authoritative or shared across multiple K9 players tracking the same
trail, the location has to be relayed client → server via a custom
`TriggerServerEvent`, which means (per this resource's own established
posture on trusting client claims — see SPEC.md §4.3's explicit
server-never-trusts-client-model note) a modified client could in principle
report a fabricated damage coordinate. For a cosmetic tracking-minigame
feature this is likely an acceptable risk (nothing security-critical hinges
on trail accuracy, unlike the certification system), but it's a real trust
boundary worth one sentence in the design doc rather than assuming
server-side capture is possible — it isn't, natively.

---

## 3. Water-crossing detection (groundwork for the *separate* water-tracking pair)

**Bottom line: real natives exist for this and are fit for purpose, but they
are client-only — same hard constraint as above.** Passing this section
along since I finished the scent/blood research with time to spare, per the
task's ask, for whichever pair picks up water-tracking design.

### `GET_WATER_HEIGHT(float x, float y, float z, float* height)` → `BOOL`
- Cross-checked via an independent GitHub native-wrapper library citing this
  exact signature and behavior note (not the primary CFX doc page, which was
  unreachable). Sets `height` to the world Z of the water surface at that
  XY and returns whether water was found there.
- **Known limitation, explicitly called out in the source I could
  cross-check:** works for seas/lakes, but is documented as unreliable for
  shallow rivers (the example given: Raton Canyon returns `-100000.0`,
  i.e. "no water found" even though there visibly is a shallow river) — flag
  this directly for the water-tracking pair, since "does the trail cross a
  river" is exactly the shallow-water case this native is known to get
  wrong. `IS_ENTITY_IN_WATER` (below) may be a more reliable fallback for
  "is the K9 currently standing in any water," even if it can't tell you
  the water's height/depth at an arbitrary point ahead on the path.
- **Client-only** — same architectural reason as the damage event above:
  the FiveM server process doesn't load world/map/water geometry at all, so
  no native that queries world geometry (water height, collision probes,
  ground height) can run server-side. This is well-established FiveM
  architecture knowledge; I could not doc-cross-check the specific `apiset`
  tag on this native this session (egress blocked), but it follows directly
  from how the server process works and matches every independent source
  found. If the water-tracking design assumes it can validate a "trail
  crossed water" check server-side, that assumption is wrong — the check
  has to happen client-side and be relayed if the server needs to know
  about it, with the same trust-boundary caveat as §2 above.

### `GET_WATER_HEIGHT_NO_WAVES(float x, float y, float z, float* height)` → `BOOL`
- Same shape as above, without wave animation offset — likely the *more*
  useful variant for a gameplay check like "is there water at this point,"
  since it gives a stable value rather than one oscillating with wave
  animation frame-to-frame. Listed in the source I cross-checked as
  officially undocumented (`@todo` in the native DB) — real and callable,
  but CFX's own doc text for it is thin/absent, so behavior nuances beyond
  "no wave offset" aren't independently confirmable this session.

### `IS_ENTITY_IN_WATER(Entity entity)` → `BOOL`
- Cross-checked (namespace `ENTITY`, confirmed real, hash `0xCFB0A0D8EDD145A3`
  per multiple independent citations). Simple boolean — client-side. Good
  for "is the K9 physically in water right now," not for "does the path
  ahead cross water" (that needs `GetWaterHeight`/`GetWaterHeightNoWaves`
  sampled at points along the path, or a vertical probe).

### `TEST_VERTICAL_PROBE_AGAINST_ALL_WATER(float x, float y, float z, ..., ...)` → `BOOL`
- Found referenced in an independent native-wrapper source but listed there
  as **undocumented** (`@todo`) with unclear trailing parameters (`Any p3,
  Any* p4` in that source, unresolved). I can confirm this native **exists**
  and is real, but I cannot confirm its exact parameter meaning or the
  correct value to pass for those trailing args from what was reachable this
  session — flagging as **not safe to rely on from memory alone**; whoever
  picks up water-tracking should verify this one specifically against a live
  docs.fivem.net page (or a decompiled nativedb dump) before using it,
  rather than trusting either their memory or this note's best-effort
  citation.

**Summary for the water-tracking pair:** the groundwork is real and
achievable (this is not a "needs a custom asset" gap like the PiP camera
item in SPEC.md §7) — `GetWaterHeight`/`GetWaterHeightNoWaves` sampled along
the trail's point list, or `IsEntityInWater` for "is the K9 in water right
now," are the correct tools, all client-only, with the shallow-water caveat
on `GetWaterHeight` specifically. `TestVerticalProbeAgainstAllWater`
warrants its own verification pass before being relied on for anything more
precise than the two height getters already provide.

---

## Open items / things I could not confirm this session (egress-blocked)

1. Primary-source confirmation of `DrawMarker`, `SetBlipRoute`,
   `GetWaterHeight` family, and the damage natives' exact CFX doc pages —
   `docs.fivem.net` and known mirrors were all blocked by the environment's
   egress proxy for the duration of this task. Everything above is
   cross-checked against multiple independent secondary sources instead;
   nothing is presented as confirmed where only a single, single-source
   memory recall was available.
2. `CEventNetworkEntityDamage` args[3], [5], [6] — only args[1], [2], [4],
   [7] were corroborated across independent sources.
3. `TEST_VERTICAL_PROBE_AGAINST_ALL_WATER`'s trailing parameter shape.

Reach out (SendMessage) if any of the above needs a second verification pass
once egress access changes, or if the design needs a specific native's
behavior nailed down further before Phase 2 implementation starts.
