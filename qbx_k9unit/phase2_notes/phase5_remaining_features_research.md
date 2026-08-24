# Phase 5 remaining features — closing the research gap

Author: technology-scout pass, 2026-08-24, jlwood17190665@gmail.com.

Status: **pure research, read-only.** No `.lua`, `config.lua`, or `SPEC.md`
file was touched to produce this document — every existing file in this
resource is either owned by another live agent or off limits this session;
this file only reads them. Scope: the three Phase 5 items
`phase2_notes/phase5_features_research.md` left genuinely open —
**`ProximityAudioFX`**, **`PropAttachments`**, **`FetchMechanic`**.
`AdvancedBarkRadial` and `DeployableKennel` are already implemented
(`config.lua`'s `Config.AdvancedBarkRadial`/`Config.DeployableKennel`,
`client`/`server` `kennel.lua`, confirmed by direct read this session) and
`CameraFeedPiP` was already concluded impossible — none of the three are
re-researched here.

**Confidence convention** (same standard as both prior notes files this
task named): a claim is CONFIRMED only with two independent sources; a
single-source lead is PLAUSIBLE/UNCONFIRMED and flagged as such; an absence
of evidence is recorded as "not found this session," never silently
upgraded to "does not exist."

**Network note — reproduced and extended.** Every domain the prior two
passes recorded as blocked (`docs.fivem.net`, `forum.cfx.re`,
`gtaforums.com`, `gta.fandom.com`, `gtahash.com`, `gtax.dev`) was blocked
again this session where re-tried. **Newly confirmed blocked/unreachable
this session** (not previously recorded, worth carrying forward so a future
pass doesn't re-try them): `gtamods.com`, `pastebin.com`, `rebarv.com`,
`docs.altv.mp`, `www.gta5-mods.com` (all `EGRESS_BLOCKED`); `altv.stuyk.com`
(DNS failure, `ENOTFOUND`); `web.archive.org` is refused categorically by
this session's `WebFetch` tool itself ("Claude Code is unable to fetch from
web.archive.org"), independent of the egress proxy. **Also newly found this
session:** `github.com/search?type=code` (the code-search UI) requires
sign-in and returns zero results to this tool regardless of query — a
tooling limitation distinct from the domain-block list above, recorded so a
future pass knows not to rely on it. As before, `github.com` HTML pages and
`raw.githubusercontent.com` file reads were reachable throughout and are
the basis for every finding below that claims to have read real source.

---

## 1. ProximityAudioFX (`Config.Features.ProximityAudioFX`)

### Recap of the crux (read before re-researching, per process)
`SPEC.md` §6.7: "Growl/pant volume attenuates by distance to a hiding
suspect... purely a volume/pitch parameter on an existing
`PlaySoundFromEntity` call, no new engine feature required." The prior pass
(`phase5_features_research.md` §2) found the mechanism *plausible*
(`PLAY_SOUND_FROM_ENTITY`'s free 3D falloff; `SET_VARIABLE_ON_SOUND` as the
scripted-attenuation candidate) but found **zero community precedent** for
the gameplay idea itself, and flagged as an open question whether a real
authored soundset would even expose a usable `SetVariableOnSound` variable
name. `dependency_and_audio_status.md` then established, independently, the
actual audio baseline this resource has: **no real audio assets exist at
all** — `BARK_SOUND_NAME`/`K9_SOUND_SET` (`client/main.lua`) and
`Config.AdvancedBarkRadial`'s per-variant `sound` strings (`config.lua`) are
placeholder names that resolve to a harmless `PlaySoundFromEntity` no-op —
and recommended extending this resource's already-proven, always-loaded NUI
bridge (`html/app.js`/`client/hud.lua`) with real `.ogg` files as a cheaper
path than authoring RAGE `.awc`/REL audio banks. **This is the actual
starting condition `ProximityAudioFX` has to be evaluated against, not the
RAGE-bank framing §6.7's wording assumes** — this is exactly what this
pass was asked to determine, and is this section's central finding.

### Community precedent — re-checked, not re-derived: CONFIRMS "no precedent," from a new angle
Targeted searches this session (`"FiveM proximity audio growl detection
hidden player script"`, `"FiveM SetVariableOnSound script example"`) found
no FiveM/GTA script anywhere that scales a sound's intensity by live
distance to a hidden target. The one genuinely new, relevant data point
found this session **strengthens rather than refutes** the "likely novel"
verdict, from a different direction: `plunkettscott/interact-sound` — a
real, widely-referenced FiveM NUI-audio library (independently confirmed in
use by at least two other public resources read this session, `Dracke39/
FiveM-Resources` and `qalle-git/esx_detector`) — has an explicit,
still-open `@TODO` in its own source, read directly
(`raw.githubusercontent.com/plunkettscott/interact-sound/master/client/
main.lua`): *"Change sound volume based on the distance the player is away
from the playOnEntity."* Its `PlayWithinDistance` path only does a static
distance **cutoff** at trigger time (play at fixed volume if `distance <
maxDistance`, otherwise don't play at all) — no continuous scaling.
**This means even the ecosystem's own most-established NUI positional-audio
library has never shipped basic continuous distance-to-volume scaling**,
despite the underlying web technique (a `GainNode`) being trivial. That is
new, independently-read evidence that nobody in this niche has actually
built the *simpler*, single-factor version of this idea (distance-to-
listener), which makes `ProximityAudioFX`'s more complex ask (distance to a
*third*, hidden entity, not the listener) even less likely to have any
real precedent anywhere — **confirmed, not refuted, and on stronger
evidence than the prior pass had.**

One additional, closely-relevant source read directly this session:
`Virgildev/v-k9` — a real, source-visible, **player-controlled** QBCore/OX
K9 script (the closest architectural analog to `qbx_k9unit` found in the
open-source ecosystem this session) ships real `.ogg` bark files
(`sounds/large-dog-mean-bark.ogg`, `small-dog-whin.ogg`, etc.) and plays
them via `TriggerServerEvent('InteractSound_SV:PlayWithinDistance', 30.5,
sound, 1.0)` — i.e. it depends on the exact same NUI-audio library whose
distance-scaling TODO is cited above, confirmed via direct read of
`client/main.lua`. This is a **fourth independent source** (after
`xsound`/`xyz-3dsound`/`chHyperSound` in `dependency_and_audio_status.md`)
corroborating that NUI-delivered `.ogg` playback is the ecosystem-normal way
a *player-controlled* K9 script ships real bark audio — and it is the
single most on-point source found across both sessions, since it is a real
player-controlled K9 script, not a generic positional-audio library.

### Buildability given this resource's real audio situation — THE crux, answered
The prior pass's biggest source of doubt — whether a real, authored
soundset would even expose a usable `SetVariableOnSound` variable name for
continuous scripted attenuation — **becomes moot** if this resource follows
`dependency_and_audio_status.md`'s own recommended path (NUI bridge, not a
RAGE audio bank). A plain Web Audio API `GainNode` (or even a `<audio>`
element's `.volume` property) supports continuous, scripted volume control
natively, with **zero dependency on any FiveM-specific native, RAGE
metadata, or authored RTPC variable** — this is a standard web-platform
capability, not something needing FiveM-side confirmation. In that sense,
**`ProximityAudioFX` is more mechanically buildable than the prior pass's
own verdict implied**, once the audio path is NUI-based rather than
RAGE-bank-based: the "does the soundset expose a scriptable variable"
unknown that blocked confidence in option (a) simply doesn't apply to the
NUI path. This is the direct, load-bearing answer to this pass's task: the
feature's audio mechanism is buildable on top of the audio situation this
resource actually has — but see the two real remaining gaps below, both of
which are bigger than the mechanism question was.

### Real remaining gap #1 — this needs TWO composed distance factors, not one, undersold the same way §6.7 undersells AdvancedBarkRadial's asset cost
§6.7's own wording ("purely a volume/pitch parameter... no new engine
feature required") describes a single knob. Once translated to the NUI path
(the realistic implementation), it actually requires composing two
independent distance computations that the SPEC's wording conflates,
mirroring the exact "two distinct things are being asked for" split the
prior pass already identified for the native-only framing:
1. **K9-to-suspect distance** (the real gameplay signal) — must be computed
   once (client or server) and broadcast as an intensity value alongside
   the existing `barkType`-style payload, reusing
   `'qbx_k9unit:client:playBark'`'s existing broadcast shape
   (`client/main.lua`) rather than inventing a new event.
2. **Each listening client's own distance to the K9** — the same
   per-listener falloff `dependency_and_audio_status.md` already sketched
   for ordinary bark playback (`GetDistanceBetweenCoords` from the K9 to
   *that client's own* ped, mapped to a 0–1 volume, sent via
   `SendNUIMessage`) — needed so a player standing next to the K9 hears the
   growl louder than one far away, independent of factor 1.
Neither factor alone is "the" volume; both need to multiply together. This
is real, small-to-moderate extra plumbing on top of the bark-audio bridge
`dependency_and_audio_status.md` already recommends — genuinely new work,
but built on infrastructure this resource will need anyway for
`AdvancedBarkRadial`'s own NUI-bridge migration, not a second, independent
subsystem.

### Real remaining gap #2 — "hidden suspect" detection has NO existing infrastructure to reuse, checked directly this session
The prior pass flagged this as an open question ("does 'hiding suspect'
detection reuse Phase 2's tracking/vision logic or need new detection
code?") without checking. This pass checked directly:
`server/tracking.lua`'s `findTrackableSource` callback (Phase 2's
scent/blood/gunpowder tracking, read in full this session) resolves the
**nearest still-fresh LOGGED coordinate** within a configured range — a
historical event location (an item drop, a blood-trail tick, a gunshot),
not a live entity's current position — and is **pull-based**, answering one
on-demand "Track" request at a time, not a continuously-updating push
value. **This is the closest existing kin in this codebase and it is still
the wrong shape**: `ProximityAudioFX` needs a live, continuously-sampled
distance to a *currently-hiding, currently-moving* suspect ped, which
`findTrackableSource` does not provide. A repo-wide grep for any existing
"is this ped currently hidden/crouching/stealthed" concept
(`crouch|hidden|stealth`, run this session) found nothing anywhere in this
codebase — `AgilityBasicJump`'s crouch references are about the K9's own
native locomotion input, unrelated. **"Hidden suspect" flagging is
confirmed, not just assumed, to be a genuinely new detection primitive**
with no code in this resource to build on — a real design question (who
flags a ped "hidden," server-authoritative or heuristic, and how) that sits
squarely in product-manager/config-validator territory, not a natives
question this pass can resolve.

### Verdict
**Confirmed, on stronger evidence than the prior pass had: no community
precedent exists for this specific mechanic anywhere this session could
reach**, and the closest generic analog (`interact-sound`'s own
distance-to-volume TODO) shows the *simpler* version of this idea is
unsolved in this ecosystem's most popular relevant library. **The audio
delivery mechanism is genuinely buildable, and easier than the prior pass's
RAGE-bank framing implied**, once built on the NUI bridge
`dependency_and_audio_status.md` already recommends for bark audio — but
the feature's real cost center is (a) composing two distance factors
correctly, a moderate, bark-bridge-dependent extension, and (b) designing
and building a wholly new "hidden suspect" detection primitive from
scratch, which is original design/implementation work, not a native-only
gap and not reusable from Phase 2's tracking system despite the surface
similarity. Recommend whoever specs this treat it as two line items with
very different sizes: audio delivery (small, once the bark-bridge work
lands) and hidden-suspect detection (a real, undersized-by-§6.7's-wording
design task) — not one "volume knob" feature.

### Open questions
- Who is the audio's intended listener — the K9's own player (a "getting
  warmer" gameplay hint, closest in spirit to Phase 2's scent-trail
  markers) or any nearby player (a diegetic, everyone-hears-it growl)? This
  changes which of the two distance factors above matters and whether the
  NUI message needs to reach one client or be relayed to several — not
  addressed by §6.7's wording, a real design question for product-manager.
- What flags a ped "hidden" — a crouch check, a foliage/prop proximity
  check, both, or a manual "start hiding" player action? Unresolved, no
  source or existing code in this repo answers it.

---

## 2. PropAttachments (`Config.Features.PropAttachments`)

### Recap of the blocker
`AttachEntityToEntity` is proven in this exact codebase
(`client/vehicle.lua`'s vehicle load-in). The prior pass found **no
confirmed bone name or index for a quadruped `a_c_*` skeleton** anywhere,
and its one lead (a GTAForums thread) was egress-blocked. Worth naming
directly: this codebase has **hit this exact same gap a second time**
already, independent of this research task — `PHASE3_SPEC.md` §12.5.4
(`PropDragging`) describes attaching a dragged target "near a collar/scruff
point (`AttachEntityToEntity`)" in prose, with no bone name or index ever
resolved there either, and `server/combat.lua`'s own header confirms
`PropDragging` remains unimplemented, explicitly out of scope, "still
blocked/deferred." That is corroborating, in-repo evidence that this is a
real, recurring blocker for this project specifically, not a one-off gap.

### This session's different route: name-hunting failed again, but a name was never actually necessary
Every domain that could plausibly host a documented `a_c_*` bone name was
tried and is blocked or unreachable (see Network note above — `gtamods.com`
was the single most promising new lead, and is blocked). `github.com`'s own
code-search UI, tried as a new route this session, requires sign-in and
returned nothing. Direct reads of real open-source dog-ped scripts also
came up empty on the *name* question specifically:
- `FiveMWhiz/DrTune-DogScript` (mirrored at `StreetDevlar/Devlar-DogScript`,
  both read directly): has exactly two `AttachEntityToEntity` calls. Both
  attach the (NPC) dog **to** something else — a vehicle seat bone
  (`GetEntityBoneIndexByName(vehicle, 'seat_pside_r')`, a *vehicle* bone,
  not a dog bone) and a human player's own ped bone (raw index `4103`, to
  let a player carry the dog). **Neither attaches a prop to the dog's own
  skeleton** — confirmed by direct read, not inferred.
- `Virgildev/v-k9` (the one player-controlled, source-visible K9 script
  found, see §1 above): its `client/main.lua` has **zero**
  `AttachEntityToEntity` calls of any kind, confirmed by direct read.
This is a real, additional negative data point beyond "no documentation
found": **no open-source FiveM script this session could read has ever
attempted attaching a prop to an animal ped's own skeleton**, which raises
(not lowers) confidence that this is a genuinely unattempted problem in the
accessible ecosystem, not merely an under-documented one.

### The actual different route that worked: the bone doesn't need a NAME, only an INDEX — and indices are found empirically, not documented, ecosystem-wide
Two natives, both confirmed directly from `citizenfx/natives` this session:

| Native | Hash | Namespace | Signature / behavior |
|---|---|---|---|
| `GET_WORLD_POSITION_OF_ENTITY_BONE` | `0x44A8FCB8ED227738` / alt `0x7C6339DF` | ENTITY | `Vector3 GET_WORLD_POSITION_OF_ENTITY_BONE(Entity entity, int boneIndex)` — "Returns the coordinates of an entity-bone." Nothing in the signature or description is human-specific; it takes a raw integer index and works on any entity. |
| `GET_ENTITY_BONE_INDEX_BY_NAME` | `0xFB71170B7E76ACBA` / alt `0xE4ECAC22` | ENTITY | (already confirmed by the prior pass) returns `-1` for an unrecognized name — this is the piece that needs a documented name and is the one this session still could not find for `a_c_*`. |

`AttachEntityToEntity`'s bone-index parameter accepts a raw integer either
way — **a semantic bone name was never actually load-bearing for the
mechanical attach**, only for the *convenience* of looking up an index by a
human-readable string. This reframes the open item from "find a documented
name" (a research task this environment cannot complete — every plausible
source is blocked) to "find a usable numeric index by direct in-engine
observation" (an engineering task, not a research one, completable in one
short dev-server session with no external documentation needed at all):
spawn a live `a_c_shepherd`/`a_c_rottweiler`, loop `boneIndex = 0` to a
generous ceiling (this session could not confirm the exact bone *count* for
`a_c_*` either — recommend a defensively large ceiling, e.g. 200, since an
out-of-range index is expected to fail gracefully, not crash, based on
`GetEntityBoneIndexByName`'s own documented `-1`-on-miss convention for the
sibling native), call `GetWorldPositionOfEntityBone(ped, boneIndex)` for
each, and draw a marker/label at each returned position — a developer can
then visually identify which raw index sits near the neck/collar (for a
vest) purely by looking, with zero dependency on any bone *name* ever being
documented anywhere.

This is not an invented technique — it is the same underlying primitive a
real, source-read dev tool already uses for exactly this purpose:
`DevBlocky/bonedev` ("a dev script for displaying positions of ped and
vehicle bones," source read directly) validates each bone via
`GetWorldPositionOfEntityBone`, though its own implementation loops a
**fixed table of human `BONETAG_*` names** rather than raw indices — so
`bonedev` itself would find nothing on an `a_c_*` model (every name lookup
would miss and get silently skipped), and is cited here only to confirm the
underlying native call shape works exactly as described, not as a
ready-to-use tool. A raw-index-sweep variant (not `bonedev` verbatim) is
what would actually need to be written.

Independent corroboration that raw numeric indices — not documented names —
are the ecosystem-normal way this exact problem gets solved even for
*well-documented human* skeletons: several independent, real, unrelated
FiveM carry/prop scripts found this session (`bndzor/lx-prop`,
`Caroliiiin/Caroliin_Carry`, `SYNO-SY/SY_Carry-ESX`, and the earlier-cited
`NotedDevelopment/noted_propattacher`, a purpose-built visual prop-placement
tool whose own README — read directly — confirms its core workflow is
"recalibration: finds the bone closest to where the prop currently sits and
re-attaches to it... without the prop moving in the world," i.e. exactly
the sweep-and-snap technique recommended above, generalized into a tool)
overwhelmingly use bare numeric bone indices rather than named lookups —
this is normal, established practice in this ecosystem, not a workaround
specific to animals.

### A softer fallback, worth naming honestly rather than treating the sweep as the only path
If the sweep finds no bone distinctly separate from the root/spine on a
given `a_c_*` model (plausible — quadruped mocap rigs are often simpler
than human ones, and this session found no source confirming or denying
`a_c_*`'s actual bone count/complexity), the prior pass's dismissal of
`client/vehicle.lua`'s root-bone-plus-offset approach ("does not transfer...
since the ped is invisible anyway") is worth softening, not discarding: a
**rigid**, non-articulating prop like a back-mounted vest — as opposed to a
collar that would need to visibly follow neck movement — may tolerate a
single, carefully hand-tuned per-breed (`Config.Peds` has four models)
fixed offset from the root bone well enough, the same way many real human
backpack-attachment scripts use one fixed offset from a spine bone without
multi-bone rigging. This is a real, viable fallback if the sweep
underdelivers, not a reason to skip the sweep — a genuine bone will look
and track visibly better if one exists.

### Verdict
**Still unresolved after this session's additional attempt — confirmed
honestly, not manufactured.** But the nature of the open item has changed
in a way that matters for scoping: this is no longer a blocked *research*
task (every plausible documentation source is now confirmed blocked or
silent on this specific question, across two full sessions), it is a
bounded, cheap *engineering* task — one short in-engine dev-server test
using a specific, native-confirmed technique this pass identifies, not
indefinite further searching. Recommend handing this to coder-frontend/
native-api-assistant as "write and run a 20-line raw-index bone-position
sweep against a live `a_c_shepherd`," not as "keep researching."

### Open questions
- Actual bone count/skeleton complexity of `a_c_*` models — not found by
  any source this session, needed to bound the sweep's loop ceiling
  sensibly (200 is a guess, not a confirmed figure).
- Whether the same usable index (if found) is consistent across all four
  `Config.Peds` models or needs to be found per-model — `a_c_shepherd`/
  `a_c_rottweiler`/`a_c_husky`/`a_c_chop` are plausibly different skeletons
  (different visual proportions at minimum), not confirmed either way.

---

## 3. FetchMechanic (`Config.Features.FetchMechanic`)

### Recap
`SPEC.md` §6.7: pick up, carry (attached to mouth bone), and drop a
physics prop on command. The prior pass found a real precedent
(`fruitmob/murderface-pets`) that spawns/throws/pursues a ball via native
calls, but **deletes the ball and fakes the carry with an animation**
rather than bone-attaching it — and is NPC-driven (`TaskGoToCoordAnyMeans`),
not player-driven, unlike this resource's real-player K9.

### Is a player-controlled fetch coherent at all? Yes — and it is simpler than the precedent, not just differently-shaped
`murderface-pets`' whole pursuit mechanic depends on the resource having
full AI/task authority over its own NPC ped (`TaskGoToCoordAnyMeans`).
Forcibly running that same class of native against a **real player's own
ped** would fight the player's own live input and replicate poorly over the
network — this is not a new concern invented for this pass; it is the exact
category of problem `server/combat.lua`'s own header (this codebase's own
Phase 3, `native-api-assistant` verification pass, read this session)
already documented for a related situation: several `PED`-namespace natives
originally assumed safe to call with full authority over a target entity
turned out to be either confirmed client-only or unconfirmed server-side,
and the fix in every case was to relay the action to "the one actor already
trusted for this action" (the entity's own client) rather than assume
script authority over an entity that has its own real client. A live
player-controlled K9 **is** its own trusted actor for its own movement —
so scripting an autonomous "go fetch" path for it is not just awkward, it
is the same authority mismatch this codebase has already hit and
documented once.

The resolution is not a difficult translation, it is a **simplification**:
the K9 player walks/runs to the thrown ball themselves, using their own
completely normal, already-free native locomotion — zero scripting needed
for the "pursue" leg at all — then presses an interact prompt
(ox_target/radial) to pick it up, exactly matching this resource's own
already-established "self-administered interaction" pattern
(`client/vehicle.lua`'s `EnterNearestK9Vehicle`: the player walks near a
vehicle and presses interact; the native-only snap only happens at that
point, never before). Read this way, the hardest-looking piece of the one
real precedent found (`TaskGoToCoordAnyMeans`-driven autonomous pathing) is
not something that needs adapting for this resource — **it can be deleted
outright**, since a real player doesn't need to be scripted to walk
somewhere. This is a materially more favorable finding than "an
architectural translation cost" (the prior pass's framing): once correctly
re-scoped for a real player, `FetchMechanic`'s pursue-and-retrieve loop has
*less* code to write than the NPC precedent needed, not more.

### The carry-attach, given finding 2: the SAME open item, not a harder one
This pass's PropAttachments section above resolves the framing question
("bone name" vs. "bone index," and the concrete sweep methodology) for a
neck/back attach point. **The mouth/jaw attach point `FetchMechanic` needs
is the identical open item, aimed at a different region of the same
skeleton** — not a second, independent research problem. The same raw-index
visual sweep (`GetWorldPositionOfEntityBone` over `boneIndex = 0..N` on a
live `a_c_shepherd`) that would be run once for the vest bone can, in the
same dev session, also identify a usable index near the head/jaw — this
should be scoped as **one blocking engineering task that unlocks both
features**, not two.

One real, breed-specific risk worth flagging that a rigid vest attach
doesn't share: a mouth/jaw region plausibly **articulates** during this
resource's own existing bark/pant animations
(`WORLD_DOG_BARKING_SHEPHERD`/`_ROTTWEILER`/`_RETRIEVER` scenarios, already
in real use in `client/movement.lua`) — a statically bone-attached ball
could visibly clip or float relative to the jaw during those animations in
a way a rigid back-vest, which doesn't need to track fine articulation,
would not. This is exactly the kind of thing the in-engine sweep-and-test
session should check directly (attach, then trigger the bark scenario,
watch for clipping) rather than assume either way. If it looks wrong, the
honest, already-precedented fallback is `murderface-pets`' own shortcut —
delete the object and play a carry animation/scenario instead — which this
pass's own §2 finding (that a genuine bone may not exist for this) makes a
more legitimate first-class option than a last resort, not a compromise to
be embarrassed about.

### Ball lifecycle — a better in-repo precedent exists than the external one
`murderface-pets` is the best available precedent for the **throw impulse**
specifically (`ApplyForceToEntity` giving the spawned ball its initial
arc — native-only, needs no adaptation, confirmed by the prior pass's
direct read). But for the **lifecycle** half of the feature — spawn a
persistent, multi-client-visible world object, track it by network id,
confirm creation back to the server, clean it up on disconnect/resource
stop — this resource already has its own real, shipped, more directly
relevant template: `server/kennel.lua`/`client/kennel.lua` (read this
session), built for the closely-related `DeployableKennel` feature.
That pair already solves, in this exact codebase's own conventions
(`RegisterNetEvent`/`lib.callback`, `NetworkGetNetworkIdFromEntity` +
defensive `ResolveNetworkEntity` re-resolution, a pending-placement TTL, an
`onResourceStop`/disconnect cleanup handler) precisely the "spawn a real
networked object other clients need to see and interact with, safely" shape
`FetchMechanic`'s ball needs — a closer and more idiomatic match for this
codebase than porting `murderface-pets`' own (NPC-oriented, delete-and-fake)
architecture wholesale. Recommend combining `murderface-pets`' throw-impulse
code shape with this codebase's own `kennel.lua` lifecycle pattern, rather
than treating either source as a drop-in port.

One real limit on that reuse, worth flagging rather than glossing over:
`server/kennel.lua`'s own header explains its design principle is "the
server computes the placement coords, the client only executes" —
achievable for a kennel because its spawn point is a simple forward-offset
from a stationary handler. **That principle does not transfer cleanly to a
thrown ball**, whose actual resting position depends on real-time physics
simulation (bounce, terrain) the server does not run. Recommend treating a
thrown ball's exact landing spot as a low-stakes, client-simulation-owned
cosmetic fact — closer to `client/vehicle.lua`'s own "single-player-only
effects" trust posture than to `kennel.lua`'s server-verified-placement
posture — since a ball, unlike a kennel's healing radius, carries no
gameplay-value zone that would need anti-abuse scrutiny.

`NETWORK_REQUEST_CONTROL_OF_ENTITY` (`0xB69317BF5E782347`, already
confirmed in this codebase's own `phase3_combat_natives.md`) remains the
correct prerequisite before the K9's own client attaches a ball it may not
have created itself (e.g. thrown by the handler, not the K9) — unchanged
from the prior pass, reconfirmed here.

### Verdict
**A player-controlled fetch is coherent, and simpler than the one real
community precedent once correctly re-scoped around the K9 player's own
real movement** — the precedent's hardest-looking piece
(`TaskGoToCoordAnyMeans` pathing) turns out to be unnecessary here, not
merely non-transferable. **The carry-attach is not a harder or separate
open item from `PropAttachments`' vest problem — it is the identical bone-
index gap, resolvable by the identical in-engine sweep, in the identical
dev session**, with one extra, concrete thing to visually check (clipping
during the existing bark/pant animations) that the vest attach doesn't need
to worry about. The ball's spawn/throw/lifecycle mechanics are fully
native-only and have TWO real precedents to draw from — `murderface-pets`
for the throw impulse, this codebase's own `kennel.lua` for the lifecycle —
neither needing to be ported wholesale.

### Open questions
- Whether the delete-and-animate fallback (already legitimized as a
  first-class option by this pass, not just an accepted shortcut) is
  preferred outright for the mouth-carry specifically, sidestepping the
  clipping risk entirely — a real fidelity/effort call for whoever specs
  this, now informed by a concrete risk (animation clipping) rather than an
  abstract "harder to solve" concern.
- `prop_tennis_ball` vs. a custom "evidence bag" prop — unchanged from the
  prior pass, still a content-sourcing decision, not resolved here.

---

## Summary table

| Feature | Precedent status | Mechanism buildable? | Real remaining blocker | Cost shape |
|---|---|---|---|---|
| ProximityAudioFX | **Confirmed no precedent**, on stronger evidence than before (interact-sound's own unsolved distance-to-volume TODO) | **Yes, and easier than previously framed** — NUI/`GainNode` path sidesteps the `SetVariableOnSound`/RTPC-variable uncertainty entirely | A wholly new "hidden suspect" detection primitive (confirmed: `server/tracking.lua`'s existing trail system does NOT cover this) — the real cost center, not the audio | Audio delivery: small, contingent on the bark-bridge work. Detection: moderate-to-real original design work |
| PropAttachments | No open-source precedent found for attaching a prop to an animal ped's own skeleton (checked directly against 2 more real scripts this session) | Reframed: doesn't need a bone NAME at all, only an INDEX, findable via `GetWorldPositionOfEntityBone` sweep — a bounded engineering task, not indefinite research | Exact usable index unconfirmed (no live client this session) | One short in-engine dev-server test, not further research |
| FetchMechanic | One real precedent found, NPC-driven, skips the bone-attach | Pursue/retrieve: yes, and simpler than the precedent once re-scoped for a real player. Carry-attach: same open item as PropAttachments, not harder | Same bone-index gap as PropAttachments (mouth/jaw region) + one animation-clipping risk unique to this feature | Shares PropAttachments' one blocking task; ball spawn/throw/lifecycle is fully native-only with two reusable precedents |

---

## Sources

- [GetWorldPositionOfEntityBone.md](https://github.com/citizenfx/natives/blob/master/ENTITY/GetWorldPositionOfEntityBone.md) — read directly this session
- [GetEntityBoneIndexByName.md](https://github.com/citizenfx/natives/blob/master/ENTITY/GetEntityBoneIndexByName.md) — re-confirmed this session
- [plunkettscott/interact-sound](https://github.com/plunkettscott/interact-sound) — `client/main.lua` read directly (the distance-to-volume `@TODO` finding)
- [Virgildev/v-k9](https://github.com/Virgildev/v-k9) — `client/main.lua` and `sounds/` folder listing read directly (player-controlled K9, real `.ogg` bark files, InteractSound dependency, zero `AttachEntityToEntity` calls)
- [FiveMWhiz/DrTune-DogScript](https://github.com/FiveMWhiz/DrTune-DogScript) / mirror [StreetDevlar/Devlar-DogScript](https://github.com/StreetDevlar/Devlar-DogScript) — `client.lua` read directly (both `AttachEntityToEntity` calls attach the dog outward, never a prop onto the dog)
- [DevBlocky/bonedev](https://github.com/DevBlocky/bonedev) — `cl.lua` read directly (confirms the `GetWorldPositionOfEntityBone`-based sweep/validate call shape; itself human-bone-name-gated, not directly reusable as-is)
- [NotedDevelopment/noted_propattacher](https://github.com/NotedDevelopment/noted_propattacher) — README read directly (visual sweep-and-recalibrate-to-nearest-bone workflow, corroborates the raw-index approach)
- [qalle-git/esx_detector](https://github.com/qalle-git/esx_detector) — repo landing page read (independent confirmation of `interact-sound`'s ecosystem usage; not itself a proximity-detection precedent, a weapon-possession alert script)
- This codebase's own `client/main.lua` (bark placeholder), `client/vehicle.lua` (`AttachEntityToEntity`/self-administered interaction precedent), `server/tracking.lua` (`findTrackableSource`, read directly, confirmed NOT a live-entity detection source), `server/combat.lua` and `PHASE3_SPEC.md` §12.5.4 (PropDragging's own unresolved "collar/scruff point" — corroborating this is a recurring gap), `server/kennel.lua`/`client/kennel.lua` (reusable lifecycle template for the ball), `config.lua` (`Config.Peds`, `Config.AdvancedBarkRadial`, `Config.DeployableKennel`)
- Carried forward, not re-derived: `phase2_notes/phase5_features_research.md` (original six-feature pass) and `phase2_notes/dependency_and_audio_status.md` (audio-baseline/NUI-bridge finding)
- Search-engine-indexed only, not independently source-confirmed this session: raw bone index values (`60309`, `28422`) attributed to `bndzor/lx-prop`/`Caroliiiin/Caroliin_Carry`/`SYNO-SY/SY_Carry-ESX` — cited only as corroboration that raw-index (not name-based) attachment is ecosystem-normal, not as verified specific values for any use in this codebase

**Blocked/unreachable this session** (see Network note above for the full
list and the distinction between egress-proxy blocks and tool-level
refusals): `gtamods.com`, `pastebin.com`, `rebarv.com`, `docs.altv.mp`,
`www.gta5-mods.com`, `altv.stuyk.com` (DNS), `web.archive.org` (tool
refusal), `github.com/search?type=code` (auth wall, not a network block).
