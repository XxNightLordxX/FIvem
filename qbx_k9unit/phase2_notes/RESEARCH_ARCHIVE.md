# qbx_k9unit — Research Archive

**Consolidated 2026-08-25 (documentation pass) from 24 separate files down to
this one.** This folder used to hold 24 individual research/design notes
written during development — native-verification passes, security reviews,
and design sketches, each 1,000-3,500 words of process narration (what was
searched, what was blocked, how confident each finding was) plus a handful
of load-bearing facts. Reading all 24 against the actual shipped code showed
the same pattern every time: **the load-bearing finding is already restated,
usually more precisely and more currently, in the header comment of the
`.lua` file it informed.** A citation in a code comment is not a reason to
keep a whole research diary alive forever — this page keeps the parts that
aren't fully duplicated elsewhere (native hash/signature tables worth having
as a lookup, and items that are *still* open today), and drops the rest.

**If something here disagrees with the code, the code wins.** Every section
below is a condensed summary, not a verbatim copy — read the cited `.lua`
file's own header comment for the authoritative, current version of anything
that shipped.

## Where each old file went

| Old file | Status |
|---|---|
| `thermal_night_vision.md`, `thermal_night_vision_natives.md` | Merged into [Vision](#vision) below |
| `scent_blood_tracking.md`, `scent_blood_natives.md`, `water_gunpowder_tracking.md`, `water_gunpowder_natives.md` | Merged into [Tracking](#tracking) below |
| `scent_source_resolution.md` | Merged into [Scent source resolution](#scent-source-resolution) below |
| `door_interaction.md`, `door_interaction_natives.md`, `door_interaction_security_review.md` | Merged into [Door interaction](#door-interaction) below |
| `contraband_search_contract.md`, `contraband_search_security_review.md` | Merged into [Contraband search](#contraband-search) below |
| `phase3_combat_natives.md`, `phase3_combat_patterns.md` | Merged into [Phase 3 combat](#phase-3-combat) below |
| `phase3_handler_partnership_decision.md` | Merged into [Handler partnership](#handler-partnership) below |
| `phase4_hud_bridge_design.md`, `phase4_hud_early_design.md` | Merged into [Vitality HUD bridge](#hud-bridge) below |
| `phase4_xp_schema_notes.md` | Merged into [XP schema](#xp-schema) below |
| `phase5_features_research.md`, `phase5_remaining_features_research.md` | Merged into [Phase 5 research](#phase-5-research) below |
| `dependency_and_audio_status.md` | Merged into [Dependencies and audio](#dependencies-and-audio) below |
| `client_event_trust_boundary.md` | Merged into [Trust boundary](#trust-boundary) below |
| `EXPORT_TRACKING.md` | **Deleted, no replacement here.** It was a Phase 1/2-era public-surface tracking sheet; `README.md`'s ["Public API (exports)"](../README.md#public-api-exports) section is the current, far more complete version of the same thing. Use that instead. |
| `native_verification_pass.md` | **Deleted, no replacement here.** Every finding in it was either already applied to the citing file's own header (the one outstanding item — `server/combat.lua`'s `SetEntityCanBeDamaged` justification — was corrected as part of this same pass) or superseded by `config.lua`'s own later text. Nothing in it was still uniquely true anywhere. |

---

<a id="vision"></a>
## Vision — thermal and night

Implemented in `client/vision.lua`. Two confirmed, dedicated toggle natives
— not the `SetTimecycleModifier` the original spec draft guessed:

| Effect | Native | Hash | Getter |
|---|---|---|---|
| Thermal | `SetSeethrough(BOOL)` | `0x7E08924259E08CE0` | `IsSeethroughActive()` |
| Night | `SetNightvision(BOOL)` | `0x18F621F7A5B1F85D` | `IsNightvisionActive()` |

Both are genuine toggle-and-forget booleans (confirmed via the CitizenFX C#
SDK's `Game.cs`, which wraps them as plain get/set properties, plus several
real-world resources that only ever call them once per state change, never
in a per-frame loop). `SetTimecycleModifier` is a real, separate native
correctly reserved for the unrelated contraband screen-filter effect
(`ContrabandScreenFX`) — not used for vision at all.

Access gate is `IsOwnModelK9()` only (not `CanShowK9UI()`): vision is framed
as the K9's own innate perception, not a departmental privilege — the same
reasoning that later informed the [Vitality HUD](#hud-bridge)'s *opposite*
conclusion (a monitoring instrument, gated on `CanShowK9UI()`). Both
natives need an explicit forced-off on every exit path (manual toggle,
resource stop, death, losing K9 access) since neither one resets on its
own — see `client/vision.lua`'s own maintenance-thread comment for the
current, shipped implementation of that cleanup.

---

<a id="tracking"></a>
## Tracking — scent, blood, water, gunpowder

Implemented in `client/tracking.lua` / `server/tracking.lua`. Confirmed
natives (all client-side; the server never runs game-event simulation or
world/water geometry, so all of this is necessarily relayed):

| Purpose | Native | Notes |
|---|---|---|
| Blood-trail source | `gameEventTriggered('CEventNetworkEntityDamage', ...)` | `data[1]` = victim entity handle (confirmed); does **not** fire for script-applied damage, only organic gameplay damage — a real, documented gap, not a bug. |
| Gunpowder-trail source | `IsPedShooting(ped)` (`0x34616828CD07F1A1`), debounced false→true | Per-client self-poll, no nearby-ped scan needed. |
| Breadcrumb rendering | `DrawMarker` | Per-frame, client-only; no native does "reveal a trail" as a concept — this is entirely custom rendering. |
| Water-crossing check | `GetWaterHeightNoWaves` (`0x8EE6B53CE13A9794`) preferred over `GetWaterHeight` | No-waves variant is frame-stable, which matters for a periodic path sample; plain `GetWaterHeight` is known-unreliable for shallow rivers. |
| In-water state | `IsEntityInWater`, `IsPedSwimming` | Live-position checks only, not useful for testing an arbitrary point ahead on a trail. |

**Deliberate accepted risk, not a bug ("FORGED TRAIL DECISION"):**
`relayDamageEvent`/`relayWeaponFire` are payload-less by design (the server
never trusts a client-claimed coordinate, only re-derives the reporting
client's own live position) — but that also means a modified client can
fire either event with no real damage/shot having occurred, planting a
fabricated trail source. This is accepted: tracking grants no real
capability, a false report just wastes an officer's time, and the only
two candidate server-side corroboration checks (health delta, ammo delta)
both have real false-negative risk against legitimate reports (armor,
weapon switches). Revisit only if a future feature ever conditions
something server-authoritative on a resolved trail source. This does
**not** apply to scent — see below.

---

<a id="scent-source-resolution"></a>
## Scent source resolution

`ox_inventory` exposes a real, confirmed, server-to-server hook:
`exports.ox_inventory:registerHook('swapItems', callback)`. It fires
synchronously on every item move ox_inventory processes, including a
ground-drop (`payload.toType == 'drop'`), and carries `payload.source` —
ox_inventory's own resolved source for the request, not a client-relabelable
value. This is what backs scent-trail source capture in
`server/tracking.lua` today, and it is a **smaller** trust surface than
blood/gunpowder: there is no client-triggerable path into this hook at all,
so scent doesn't need — and doesn't get — a `relayCooldownMs`-style rate
limit the way blood/gunpowder do. The hook fires *before* the drop
inventory/coords exist, so don't try to read them back from inside the
hook callback itself; resolve the dropping player's own live position
instead (`GetEntityCoords(GetPlayerPed(payload.source))`).

A client-side "scan the world for dropped-item props" fallback was
considered and rejected: it would have been strictly worse on trust
(client-claimed coordinate), reliability (ox_inventory drops aren't
guaranteed to spawn a visible pickup prop), and effort, for no benefit once
the hook above was confirmed real.

---

<a id="door-interaction"></a>
## Door interaction — nudge-open and scratch-to-alert

Implemented in `client/movement.lua` (both mechanics) and `server/main.lua`
(`relayDoorScratch`).

**GTA's native door system (`DOOR_SYSTEM_*`, `OBJECT` namespace) is real but
narrow** — it only covers doors registered via `AddDoorToSystem` (mostly
Rockstar's own IPL-authored interiors, plus anything a script explicitly
registered). Most FiveM door-lock resources (`ox_doorlock`-style, custom
MLO doors) do **not** use this system at all — they implement their own
lock flag entirely outside `CDoor`. That makes the native lock-state query
actively misleading for exactly the doors a real door-lock resource
manages: a door a resource considers "locked" may simply not be registered
in `CDoor` at all, so reading "not registered" as "safe to nudge" would be
a real way to violate `nudgeRequiresUnlocked`'s hard guarantee.
`SetStateOfClosestDoorOfType` and `DoorControl` are both confirmed
hardcoded to not work in multiplayer at all — don't reach for either.

**The design that shipped avoids the whole problem deliberately**: nudge-open
never reads or writes native lock state at all. It only plays a cosmetic
push animation as the K9 passes through a door it can already physically
walk through — which cannot ever bypass a lock, because nothing about the
door's actual state is touched. `Config.DoorInteraction.nudgeRequiresUnlocked`
is enforced by a resource-start `assert()` in `client/movement.lua` (fail
loudly if anyone ever sets it to anything but `true`) precisely because no
code path reads it as a real branch — the assertion exists to catch a
*future* implementer who tries to wire a real lock-bypass branch off this
flag without deliberately removing the assertion first.

**Scratch-to-alert's `doorNetId` is fully validated server-side** in
`server/main.lua`: resolved via `NetworkGetEntityFromNetworkId`,
existence-checked, and proximity-checked against the caller's own live
position before ever being broadcast — closing a confirmed, concretely
exploitable per-victim harassment vector an early draft of the handler
would have shipped with (a certified account could name *any* live
entity's netId, including another player's own ped, and have every client
who has it streamed in play a repeating alert sound anchored to that
player, from anywhere on the map). There's also a second, independent
cooldown keyed by the resolved `doorNetId` itself (not just by source),
closing the multi-account "several certified accounts each independently
respect their own per-source cooldown while collectively hammering the
same door" gap. See `server/main.lua`'s `DoorScratchCooldown`/
`DoorScratchByDoorCooldown` for the current implementation.

---

<a id="contraband-search"></a>
## Contraband search contract and security review

Implemented in `server/search.lua`. Confirmed `ox_inventory` export surface
(read against real source, not guessed): `GetInventoryItems`/`GetInventory`/
`GetItemCount`/`GetContainerFromSlot`. A slot's `.weight` is already the
*total* weight for that slot (`item.weight * count`, plus adjustments) —
summing it directly across matching slots is correct; don't re-multiply by
count. A vehicle's trunk inventory id is literally `'trunk' .. plate`,
resolved live server-side, never from a client-supplied plate string.

**Must-handle findings, all implemented in the shipped file:**
- **Container recursion.** `GetInventoryItems` only returns top-level slots
  — a container item (backpack, bag) appears as one slot named for the
  *container*, not its contents, even though its `.weight` rolls up the
  contents' total. Contraband hidden in a bag placed in a searched trunk is
  invisible to a naive scan unless the search recurses into container slots
  to an explicit max depth.
- **The contraband-alert broadcast must be distance-filtered, never a
  global `-1` broadcast the way `relayBark` is.** Unlike a bark, the
  payload necessarily identifies a specific target — a global broadcast
  would let anyone on the map (including the target's own accomplice)
  resolve who just got flagged, defeating the entire tactical point of a
  local K9 alert. The broadcast also carries `alertTier` only, never
  `totalWeight`/`contrabandFound` — those are returned solely to the
  requester.
- **Mandatory, unconditional, first-class proximity check before any
  inventory read.** The server always knows the live coordinates of any
  valid networked entity regardless of whether it's streamed in for the
  requester — without this check running first, a modified client could
  supply any vehicle/player's netId anywhere on the map and get back a real
  result, turning the feature into a server-wide search oracle.
- **Entity-type cross-check**: the resolved entity's real type (vehicle vs.
  a connected player's ped) is independently re-derived, never trusted from
  the client's `targetType` label.
- **In-flight mutex plus a cooldown timestamp written before the awaited
  ox_inventory call**, not after — closes a check-then-act race a
  cooldown alone can't close once an `await` sits between the check and the
  result.
- **`search_failed` is a distinct outcome from `contrabandFound = false`.**
  Collapsing "we couldn't check" into "we checked and it's clean" is a
  correctness bug with real in-fiction consequences, independent of
  whether it's exploitable.

---

<a id="phase-3-combat"></a>
## Phase 3 combat — natives and ecosystem research

Native verification (against `citizenfx/natives`, cross-checked where a
prior claim turned out wrong):

| Feature | Key correction found |
|---|---|
| Bite-and-Hold | Mechanical hold (`SetBlockingOfNonTemporaryEvents`, `SetPedFleeAttributes`) is real and confirmed. No confirmed sustained "bite and hold" animation exists for any breed — `creatures@rottweiler@melee@streamed_core@`/`takedown_from_back` is a real, Rottweiler-only, **one-shot** takedown pose, not a loop, and needs in-engine preview before being treated as final. |
| Non-Lethal Takedown | The real ragdoll native is `SET_PED_TO_RAGDOLL` (not `TaskRagdollPed`, which doesn't exist under that name). No dedicated fall-damage-suppression native/flag exists — the real, confirmed mechanism is bracketing the forced ragdoll with `SetEntityCanBeDamaged(target, false)` / `(target, true)`, broader than fall-damage-specific but directly satisfies "no lethal damage from the hold." `SetEntityInvincible` is explicitly **not** recommended — its own doc text notes it suppresses ragdoll on at least one damage source, which would fight the very effect this feature needs to produce. |
| Prop Dragging | `SetPedMoveRateOverride` (unlike the vision toggles above) is **not** fire-and-forget — its own doc text says "Needs to be looped," and must be re-asserted every tick the drag is active. |
| Advanced Agility | No generic ped "jump" task native exists at all — jump is native-locomotion/input-driven. `StartShapeTestCapsule`/`GetShapeTestResult` are the real, confirmed natives for obstacle detection; no quadruped vault/climb animation was found or is expected to exist as a reusable vanilla asset. |

**Ecosystem research, headline finding:** the mainstream FiveM K9-script
ecosystem (v-k9, QB-K9, ND-K9, Mato-K9, Rq-dogs) is built on a
"handler-commands-an-NPC-dog" architecture, not a player playing the dog —
so ecosystem precedent for the *NPC-target* half of every Phase 3 mechanic
is strong (native AI-suppression + forced anim, exactly this codebase's own
approach), but there is **no existing precedent anywhere surveyed** for a
*player-controlled* companion applying a hostile effect to another real
player. Treat Phase 3's player-target combat work as original design, not
as porting a known pattern. Separately: `bonz_parkour` (a real, source-read
FiveM parkour script) is a concrete, shipped example of the exact
"zero-validation vault" anti-pattern to avoid for Advanced Agility — it
lets a player "vault" into open air or through a wall, with no raycast, no
shape test, no allowlist at all.

---

<a id="handler-partnership"></a>
## Handler partnership decision (resolved)

Two Phase 3 features (Bite-and-Hold's Recall actor, Handler-Down Defense's
trigger) needed a "who is this K9's handler right now" answer independent
of momentary leash state (a K9 mid-foot-chase is very plausibly off-leash
exactly when a defense trigger would matter). Two options were weighed:
reuse the existing `LeashPairs` table (cheap, but leaves the off-leash case
with no defense support at all — its own disclosed, named primary use
case), or a new, independent, DB-backed partnership registry. **Resolved:
Option B** — a new `server/partnership.lua`, a `k9_partnerships` table, and
a mutually-consented "Partner Up" action, all implemented and shipped
behind `Config.Features.HandlerPartnership`. Reusing the leash table was
rejected outright, not merely deprioritized, because it fails the primary
use case it was being asked to serve.

---

<a id="hud-bridge"></a>
## Vitality HUD — Lua↔JS bridge design

Implemented in `client/hud.lua` + `html/index.html`/`style.css`/`app.js`.
This was this resource's first NUI surface, designed across two competing
draft notes; the one summarized here (`phase4_hud_bridge_design.md`) is the
one whose naming and payload shape actually shipped — the other draft
(`phase4_hud_early_design.md`) proposed a different, never-built naming
scheme (`k9hud:visibility`/`k9hud:update`/`qbx_k9unit:nui:hudReady`) and is
recorded here only as "considered, not chosen."

**Naming**: NUI callback/message names use a `<surface>:<verbNoun>` shape
(`hud:ready`, `hud:updateVitals`) rather than this resource's
`qbx_k9unit:client:`/`qbx_k9unit:server:` net-event prefix — that prefix
exists to avoid colliding with other *resources'* global event namespace,
which doesn't apply to NUI (a `RegisterNUICallback` is already scoped by
`GetParentResourceName()` in the URL; a `SendNUIMessage` only ever reaches
this resource's own page).

**Payload**: one combined message (`visible` plus all four vitals values
together), not split into separate visibility/update messages — a split
design has two moving parts that can desync if one message is ever dropped
(NUI message delivery isn't queued or retried). `visible = false` still
carries the last real values, not zeros, so a quick re-show doesn't flash
stale zeros first.

**Focus**: `SetNuiFocus` is never called for this HUD. It's a passive,
non-interactive overlay — there is no open/close focus state to manage at
all, and calling it would be a bug here, not a missing feature. The CSS
counterpart: the root container needs `pointer-events: none` so it can
never intercept a click even though it's still painting on top of the game.

**Cadence**: poll every ~250ms, only actually push when a value moved past
a small epsilon, force a heartbeat push at least every ~1000ms regardless
so a dropped message self-heals, push immediately (bypassing both) on any
visibility transition, and push an immediate snapshot the moment `hud:ready`
fires (a message sent before the page's JS has attached its listener is
lost, not buffered — this closes that race).

**Visibility gate: `CanShowK9UI()`, not `IsOwnModelK9()` alone** — the
opposite conclusion from [Vision](#vision) above, and worth noting why:
SPEC.md's own Phase 1 acceptance criteria names the vitality HUD in the
same clause as the radial menu, under the same certification gate. The
vitality HUD is a department-issued monitoring instrument, not the K9's own
sense organs — an uncertified player wearing a K9 model has no in-fiction
standing to see an official department readout, same as they don't get the
radial menu's Leash/Vehicle actions.

**Still genuinely open, not resolved by either draft:** whether a
handler/officer partner should see *their* K9's vitals while nearby/leashed
to them (the "...or nearby" half of the original spec wording) — this
would need the payload to identify whose vitals are shown and a second
local predicate reusing `IsLeashed()`. Not blocking; ship self-vitals first,
extend additively later if this is confirmed in scope.

---

<a id="xp-schema"></a>
## XP / progression schema design

Implemented in `sql/install.sql` (`k9_progression` table) and
`server/progression.lua`. XP is real, mechanical, capability-adjacent state
— crossing a tier threshold changes a K9's actual movement speed and scent
range — which puts it in the same category as `k9_certifications`, not a
cosmetic `qbx_core` metadata mirror: it needs offline correction (an admin
adjusting a disconnected player's XP), atomic accumulation (`INSERT ...
ON DUPLICATE KEY UPDATE xp = xp + ?`, avoiding a Lua-side read-modify-write
race across concurrent award sources), and queryability without scanning
every player's metadata blob.

Schema: one row per `citizenid` (not per `citizenid, job`) — XP is scoped to
the K9 character itself, deliberately reading "persists per-handler" as
"survives a department change," not mirroring `k9_certifications`' job
scoping. This is a real, still-open design fork
(`Config.XP.scopePerCitizenidOrJob`, currently only `'citizenid'` is
implemented) — see `PHASE4_SPEC.md` §13.6 item 2 if this ever needs
revisiting. The tier lookup itself deliberately is **not** computed in SQL
(no generated column) — `Config.XPTiers` is code-side and config-driven, so
baking its thresholds into a SQL `CASE` would create a second, driftable
copy of the same boundaries.

**Still open, not decided:** whether a separate, append-only `k9_xp_log`
table (mirroring `k9_search_log`'s shape) is also worth adding for
anti-cheat/dispute auditing, given XP is arguably more exploit-sensitive
than a search (it directly buys a mechanical advantage). `k9_progression`
alone answers "what is this K9's current XP," not "prove how it got
there." Flagged for whoever next reviews the XP economy, not decided here.

---

<a id="phase-5-research"></a>
## Phase 5 features — native and ecosystem research

`AdvancedBarkRadial` and `DeployableKennel` are implemented and shipped
(five real `.ogg` files ship under `html/sounds/`, per
`html/sounds/CREDITS.md`; `prop_doghouse_01` was refuted during
implementation and replaced with the confirmed-real `prop_dog_cage_01`, see
`config.lua`'s own `Config.DeployableKennel` comment). `CameraFeedPiP`
stays `false` and is expected to permanently: a true inset live-3D-video
picture-in-picture is **not achievable** with stock FiveM natives (DUI/NUI
textures render HTML, not the 3D scene — there is no native "camera to
runtime texture" hook), corroborated by a still-open upstream
`citizenfx/fivem` GitHub issue (#3835) asking Cfx for exactly this
capability. A full-screen K9-POV camera **takeover** (not an inset) is
fully native-only and achievable (`CreateCam`/`RenderScriptCams`, the same
mechanism real FiveM dashcam scripts use) if a future pass wants that
narrower spike instead.

**`PropAttachments`/`FetchMechanic` remain genuinely unresolved** and are
why both still use the root-bone placeholder attach point pending the
dev-only bone-index sweep (`client/bonetool.lua`/`server/bonetool.lua`,
gated on `job.isboss` plus `setr qbx_k9unit_enable_bone_dev_tool 1`) —
built specifically in response to this research. Key finding: a bone does
**not** need a documented *name* for `AttachEntityToEntity` to work, only a
numeric *index* — `GetWorldPositionOfEntityBone(entity, boneIndex)` takes a
raw integer and works on any entity, human-named or not. No open-source
FiveM script found in research ever attached a prop to an animal ped's own
skeleton (several attach an NPC dog *to* something else — a vehicle seat,
a carrying player — never a prop onto the dog). This reframes the open
item from "find a documented bone name" (blocked indefinitely — every
plausible source is unreachable) to "run a one-time in-engine sweep": spawn
a live K9 model, loop a bone-index range, call
`GetWorldPositionOfEntityBone` at each, and visually identify a usable
index near the neck/back (vest) and near the head/jaw (fetch carry) by
eye. If no distinct bone exists, a hand-tuned fixed offset from the root
bone is a legitimate fallback for a *rigid* prop like a vest — the fetch
mouth-carry additionally needs an in-engine check for animation clipping
against the existing bark/pant scenarios, given a bone-attached prop there
would need to visibly track jaw movement.

**`FetchMechanic`'s pursue/carry logic is simpler than its one real
precedent** (`fruitmob/murderface-pets`, an NPC-driven pet script that
deletes the ball and fakes the carry with an animation rather than
bone-attaching it) once correctly re-scoped for a real player: the K9
player walks to the thrown ball using their own ordinary input — no
scripted pathing needed at all — then presses an interact prompt, the same
self-administered pattern `client/vehicle.lua`'s `EnterNearestK9Vehicle`
already established. `server/kennel.lua`/`client/kennel.lua`'s existing
spawn/track/cleanup pattern is a closer, more idiomatic lifecycle template
for the ball than porting the NPC precedent wholesale.

**`ProximityAudioFX` needs two things that don't exist yet, not one volume
knob**: (1) composing two independent distance factors (K9-to-suspect, and
each listener's own distance to the K9) rather than a single native call,
and (2) a wholly new "hidden suspect" detection primitive —
`server/tracking.lua`'s existing `findTrackableSource` is pull-based and
resolves a historical logged *coordinate*, not a live, continuously-moving
suspect ped, and is confirmed (by direct read) not to cover this. No
FiveM script surveyed does proximity-scaled audio toward a third,
hidden entity at all — not a known, portable pattern.

---

<a id="dependencies-and-audio"></a>
## Dependency maintenance and bark-audio sourcing

Both findings here are now folded into `README.md`'s ["Last verified
compatible"](../README.md#last-verified-compatible) section and
`html/sounds/CREDITS.md` respectively — recorded here only for the
reasoning behind them. Overextended (not CommunityOx) is the confirmed,
current, actively-maintained home of `ox_lib`/`ox_target`/`oxmysql`/
`ox_inventory`: Overextended briefly went dormant in 2025, CommunityOx
existed as a temporary community fork during that gap, and CommunityOx's
own GitHub org is now itself archived (marked so by GitHub, April 2026) —
confirmed from three independent sources (Overextended's own docs history,
CommunityOx's own archived-org banner, and directly-observed recent commit
activity across all four Overextended repos). `fxmanifest.lua`'s
`dependencies` block has no version-pinning syntax at all — this is an
engine limitation, not an oversight; a version table in `README.md` is
documentation for an operator to manually cross-check, not something the
manifest can enforce.

For bark audio: the cheaper path (extending this resource's own
already-working NUI bridge with real `.ogg` files, rather than authoring a
full RAGE `.awc`/REL custom audio bank) was recommended and is the path
that shipped — see `html/sounds/CREDITS.md` for the actual files and their
licensing.

---

<a id="trust-boundary"></a>
## Client-event trust boundary (`source ~= 65535`)

A client's own `TriggerEvent(name, ...)` call cannot forge a genuine
server-origin marker — confirmed directly from the `TRIGGER_EVENT_INTERNAL`
native declaration, which has no parameter for a caller to specify an
origin. FiveM's own documentation states, for exactly this scenario, that
the server sends net id `65535` for a server-originated event on the
client — so a `RegisterNetEvent` handler that should only ever legitimately
fire from a genuine server-sent trigger can and should guard on
`if source ~= 65535 then return end` as its first statement.

This closes a real, concrete gap: without it, a generic "trigger any event"
cheat menu (far more common and lower-effort than a native-calling mod
menu) could self-trigger any of this resource's `qbx_k9unit:client:*`
handlers directly — including, for the NPC-relay combat handlers, applying
or removing an effect against an NPC a *different*, legitimately-certified
K9 is mid-action against, which is real cross-player griefing, not just
self-benefit. This guard is now applied to every `qbx_k9unit:client:*`
`RegisterNetEvent` handler across the resource (`client/combat.lua`,
`client/partnership.lua`, `client/wellbeing.lua`, `client/medkit.lua`,
`client/screenfx.lua`, `client/bonetool.lua`, `client/main.lua`,
`client/fetch.lua`, `client/kennel.lua`), each with its own inline
"server-origin guard" comment pointing back to this explanation.

**What this does not, and cannot, close**: a legitimately-targeted player's
own client *honestly receiving* a genuine server-sent event and then simply
choosing not to execute the restriction it applies (skip the
`DisableControlAction` calls, or not run this resource's code at all). That
is a structural property of FiveM (a live player's ped is that player's own
client's simulation of their own input, not a flag that migrates) — it is
detectable, not preventable, and is accepted as a disclosed, guardrailed
risk (`PHASE3_SPEC.md` §12.0 item 8), not something this guard was ever
meant to address.
