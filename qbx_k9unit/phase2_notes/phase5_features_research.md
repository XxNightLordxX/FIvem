# Phase 5 features — ecosystem/native research (pre-spec)

Author: technology-scout pass, 2026-08-23, jlwood17190665@gmail.com.

Status: **pure research, read-only, ahead of any spec.** No `.lua` file,
`config.lua`, or `SPEC.md` was touched to produce this document. `SPEC.md`
§8 currently describes Phase 5 (`AdvancedBarkRadial`, `ProximityAudioFX`,
`PropAttachments`, `FetchMechanic`, `DeployableKennel`, `CameraFeedPiP`) in
one line each, all `Config.Features` flags default `false`, and nobody is
implementing this phase yet. This follows the same pattern the project used
ahead of Phase 2 (native/pattern research before `SPEC.md` §11 was written)
and ahead of `PHASE3_SPEC.md` (`phase3_combat_natives.md` /
`phase3_combat_patterns.md`). This is a research handoff for whoever specs
Phase 5 next (product-manager for the spec itself, native-api-assistant/
coder-architect for implementation) — it is not itself a spec, and does not
resolve any design fork (e.g. how `ProximityAudioFX`'s "hidden suspect"
detection radius should actually be computed) that isn't a native-
availability question.

**Network note (same as every prior `phase2_notes/*_natives.md` file):**
`docs.fivem.net`, `forum.cfx.re`, `gtaforums.com`, `gta.fandom.com`,
`gtahash.com`, and `gtax.dev` are all blocked by this environment's egress
proxy (confirmed again this session). Every native hash/signature below
traces to `raw.githubusercontent.com/citizenfx/natives` (the same canonical
upstream source `docs.fivem.net` itself renders from), same as every prior
native-verification pass in this project. Where a claim rests on a search-
engine-indexed page rather than a source file this session actually read,
that is flagged per-item, not presented with native-doc-level confidence —
same discipline `phase3_combat_natives.md` established for its Rottweiler
melee-clip finding.

---

## 1. AdvancedBarkRadial (`Config.Features.AdvancedBarkRadial`)

### What this needs to do
`SPEC.md` §6.7: "Radial bark options (aggressive/alert/calm) each play a
distinct sound asset attached to the K9 entity" — i.e. more bark *variety*
routed through the same playback path Phase 1 already wired.

### Current baseline in this codebase (read before researching, per process)
`client/main.lua`'s `playBark` handler is real plumbing around a **placeholder
sound reference**, already self-documented as such:

```lua
local BARK_SOUND_NAME = 'Bark'
local BARK_SOUND_SET = 'qbx_k9unit_sounds' -- placeholder; not a real shipped soundset yet
...
PlaySoundFromEntity(-1, BARK_SOUND_NAME, entity, BARK_SOUND_SET, false, 0)
```
The comment above it already states: no bundled audio asset files exist in
this resource, there is no native "make this canine ped emit a bark voice
line on command," and `PlaySoundFromEntity` with an unrecognized sound
name/set is a harmless no-op (doesn't error) — so Phase 1 ships safely with
zero real audio. `barkType` is explicitly untyped/unused today ("only one
generic bark exists... Phase 5's `AdvancedBarkRadial` is where per-type
sound selection would get added").

### Confirmed natives
| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `PLAY_SOUND_FROM_ENTITY` | `0xE65F427EB70AB1ED` / alt `0x95AE00F8` | AUDIO | `void PLAY_SOUND_FROM_ENTITY(int soundId, char* audioName, Entity entity, char* audioRef, BOOL isNetwork, Any p5)` — already the exact native this codebase uses; adding variety is a matter of passing a different `audioName`/`audioRef` pair per bark type, not a new native. |
| `REQUEST_SCRIPT_AUDIO_BANK` | `0x2F844A8B08D76685` / alt `0x21322887` | AUDIO | `BOOL REQUEST_SCRIPT_AUDIO_BANK(char* bankName, BOOL bOverNetwork)` — "requests and returns true/false if the script audio bank has loaded." This is the real native gate for loading a **custom, non-vanilla** sound bank before `PlaySoundFromEntity` can find it — not previously named anywhere in this codebase, and not needed for Phase 1's placeholder since it never resolves to a real bank today. |

### The asset pipeline this actually requires — CONFIRMED to be non-trivial, sharper than the existing placeholder comment implies
Community precedent for adding a *custom* soundset callable via
`PlaySoundFromEntity`/`RequestScriptAudioBank` (a siren-pack writeup) confirms
the real shape of the work: a custom bank is **not** "drop in a .ogg file" —
it requires **`.awc` audio container files plus custom `dat151`/`dat54` REL
metadata files** compiled into a DLC-shaped audio resource folder
(`sfx/dlc_<name>/...` + `config/*.dat` referenced from `fxmanifest.lua`),
loaded at runtime via `RequestScriptAudioBank`. This is a real, non-code
authoring pipeline (encoding + RAGE audio metadata authoring), not a
scripting task — confirms and sharpens `client/main.lua`'s own existing
comment ("this is not a zero-asset feature... coordinate with
asset-pipeline-agent"), which undersold it slightly by not naming the
`.awc`/`dat151`/`dat54` requirement specifically.
Source (one, not independently cross-verified against a second explainer
this session — flagging per this project's confidence convention):
a Cfx forum-adjacent siren-pack write-up surfaced via `WebSearch`
(`WMServerSirens`, `Walsheyy/WMServerSirens`, GitHub README).

### Verdict — confirms the task's framing: this **multiplies**, not just extends, the existing Phase 1 bark-audio gap
Phase 1 ships with **one** unresolved placeholder soundset (`'qbx_k9unit_sounds'`,
currently a documented, accepted no-op gap). `AdvancedBarkRadial` as scoped in
§6.7 needs **at least three** distinct, real, correctly-authored sound
assets (aggressive/alert/calm) run through the *same* non-trivial
`.awc`/REL authoring pipeline described above — not three plain audio files,
three real RAGE-audio-bank entries. This is the same accepted asset gap
from Phase 1, tripled in scope, not a new category of gap. Recommend
whoever specs this phase treat "source/author three real bark soundsets"
as an explicit, sized line item (same asset-pipeline-agent coordination
Phase 1's comment already calls for), not an assumed-free variety toggle.

### Community precedent
No FiveM K9/pet script's *source* was reachable this session to confirm how
any of them actually author their own bark variety (every K9 script
surveyed this session and in the prior Phase 3 pattern pass — v-k9,
empfi/QB-K9, ND-K9, Mato-K9, Rq-dogs — is closed-source or only exposed
marketing copy, not raw audio-bank source). **Explicitly no precedent found
for how the ecosystem sources multi-type bark audio** — flagging the
absence rather than guessing.

### Open questions
- Whether 3 bark types is the right count, or whether per-breed variants
  (matching `Config.Peds`' 4 configured breeds) are also expected — not
  addressed in §6.7's one-line description; a real scope question for
  whoever specs this.
- Whether licensing/sourcing real dog-bark audio (aggressive/alert/calm,
  ideally per-breed) is being done in-house or needs an external asset
  vendor — outside this document's authority to resolve, flagged per
  `SPEC.md` §9 item 7's existing "small asset requirements... need someone
  to source" note.

---

## 2. ProximityAudioFX (`Config.Features.ProximityAudioFX`)

### What this needs to do
`SPEC.md` §6.7: "Growl/pant volume attenuates by distance to a hiding
suspect... purely a volume/pitch parameter on an existing
`PlaySoundFromEntity` call, no new engine feature required."

### Confirmed natives
| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `PLAY_SOUND_FROM_ENTITY` | (as above) | AUDIO | Same native as bark playback — an entity-positioned sound already gets the game audio engine's own real-time 3D distance falloff for free (this is a core, automatic GTA audio-engine behavior for any entity-emitted sound, not something that needs a separate native call) — confirms §6.7's "no new engine feature required" claim for the *baseline* distance-falloff-as-you-walk-away behavior. |
| `SET_VARIABLE_ON_SOUND` | `0xAD6B3148A78AE9B6` / alt `0x606EE5FA` | AUDIO | `void SET_VARIABLE_ON_SOUND(int soundId, char* variableName, float value)` — "assigns a floating-point value to a named variable associated with a specific sound instance." This is the real candidate native for a *scripted* volume/pitch override beyond natural distance falloff — but it requires the underlying sound *definition* (in whatever REL/audio-bank data actually backs the sound) to expose a named RTPC-style variable in the first place. **Not confirmed this session** whether a vanilla or to-be-authored bark/growl soundset actually exposes a usable variable name (e.g. a documented `"volume"` or `"pitch"` key) — this is a data-authoring detail, not a native-availability gap, and needs confirmation against whatever soundset is actually authored for item 1 above. |

### Verdict — native-only for the mechanism, but the specific "attenuates toward a hidden suspect" gameplay logic is a scripted distance-tier system, not a single native call
Two distinct things are being asked for, and §6.7's wording blends them:
1. **Natural distance falloff as the *listening player's own camera* moves
   away from the K9** — this is free, automatic, and needs zero extra code
   beyond calling `PlaySoundFromEntity` from the K9's own position (already
   done for bark).
2. **A *gameplay-driven* intensity change tied to the K9's distance to a
   *third* entity (the hidden suspect)** — this is not something
   `PlaySoundFromEntity`/`SetVariableOnSound` gives you "for free"; it needs
   scripted logic (poll the K9-to-suspect distance, then either (a) call
   `SetVariableOnSound` if the authored soundset exposes a volume/pitch
   variable, confirmed real as a mechanism but unconfirmed as to which
   variable name would work for a not-yet-authored soundset, or (b) the
   safer, fully-confirmed-native fallback: **select between multiple
   discrete pre-authored clips by distance tier** (e.g. a "growl_far" vs.
   "growl_near" pair, reusing item 1's asset pipeline) rather than
   continuously scaling one clip's pitch/volume live. Recommend (b) as the
   lower-risk implementation path until (a)'s variable-name question is
   answered against a real authored soundset.

### Community precedent
**None found.** Targeted searches for FiveM stealth/detection audio scripts
that scale a growl/pant sound by proximity to a hidden target surfaced only
unrelated hits (a hunger/thirst "growl" notification script, generic voice-
distance-range scripts, a prop-hunt "Hide and Seek" gamemode with no audio-
proximity mechanic documented). This appears to be a genuinely novel
mechanic for this niche, not a known, portable pattern — treat as original
design/implementation effort when scoping cost, not "porting a known
pattern," mirroring the same honest framing `phase3_combat_patterns.md`
already used for Phase 3's player-target combat gap.

### Open questions
- Whether "hiding suspect" detection (the trigger condition, not the audio
  itself) reuses Phase 2's existing tracking/vision detection logic
  (`server/tracking.lua`/`client/vision.lua`) or needs new detection code —
  not addressed by §6.7's one-line description; a real scope question,
  not a native-availability one.
- Whether a real authored soundset (once item 1 exists) actually exposes a
  usable `SetVariableOnSound` variable name — unconfirmed, needs testing
  against the real asset once it exists, not resolvable from documentation
  alone.

---

## 3. PropAttachments (`Config.Features.PropAttachments`)

### What this needs to do
`SPEC.md` §6.7 / §7: attach a configured prop (vest, harness, tracking
camera) to a configured bone on the K9 model via `AttachEntityToEntity`.

### Confirmed natives
| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `ATTACH_ENTITY_TO_ENTITY` | `0x6B9BBD38AB0796DF` / alt `0xEC024237` | ENTITY | Full signature already confirmed in `phase3_combat_natives.md` §1 — already in real, working use in this exact codebase (`client/vehicle.lua`'s vehicle load-in: `AttachEntityToEntity(ped, vehicle, 0, 0.0, -1.5, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)`). No new native needed for the mechanical attach itself. |
| `GET_ENTITY_BONE_INDEX_BY_NAME` | `0xFB71170B7E76ACBA` / alt `0xE4ECAC22` | ENTITY | `int GET_ENTITY_BONE_INDEX_BY_NAME(Entity entity, char* boneName)` — case-insensitive, returns `-1` if the named bone doesn't exist on that specific entity's actual skeleton. **This is the recommended lookup for an animal ped**, not `GET_PED_BONE_INDEX`, because it queries the entity's own real skeleton by string name rather than relying on a bone-ID enum defined around the human rig (see caveat below). |
| `GET_PED_BONE_INDEX` | `0x3F428D08BE5AAE31` / alt `0x259C6BA2` | PED | `int GET_PED_BONE_INDEX(Ped ped, int boneId)` — takes an `ePedBoneId` enum value (e.g. `SKEL_Head`, `SKEL_Spine2`). **Caveat, not independently confirmed either way this session:** this enum's bone IDs are defined around the human/`mp_`/`a_m_`/`a_f_` skeleton rig. Whether a quadruped `a_c_*` animal ped model's skeleton actually maps the same `ePedBoneId` values to sensible equivalent bones (e.g. does `SKEL_Head` resolve to the dog's actual head bone, or something nonsensical/root-fallback) was **not confirmed this session** — no source directly addressing animal-ped bone-ID mapping was found via the accessible search tooling (the one closest lead, a GTAForums thread titled "[SOLVED] accessing skeleton bones of animals," could not be opened — `gtaforums.com` is blocked by this environment's egress proxy). |

### The bone-name question — CONFIRMED UNRESOLVED, flagged honestly rather than guessed
No specific animal-skeleton bone name (a "collar," "back," or "spine"
equivalent for a quadruped rig) was confirmed this session for any
`Config.Peds` model. This codebase's own existing precedent
(`client/vehicle.lua`) sidesteps the question entirely by using bone index
`0` (the root bone) with a documented offset, explicitly because "the ped is
invisible anyway; exact bone precision doesn't matter" for that use case —
**that precedent does not transfer here**, since a visible vest/harness prop
needs a real, correctly-placed bone, not a root-bone-plus-offset
approximation. **Recommend an in-engine bone dump** (e.g. a small dev script
enumerating `GetEntityBoneIndexByName` against a guessed list of likely
names, or a community bone-dev tool) against a live `a_c_shepherd`/
`a_c_rottweiler` ped as the concrete next verification step — not
resolvable from documentation alone this session.

### Native/component-system caveat worth flagging
Human MP/SP peds support a **12-slot component/drawable-variation system**
(`SET_PED_COMPONENT_VARIATION`, `SET_PED_PROP_INDEX`) for clothing/props
tied to model-defined slots. Based on general GTA-modding-community
knowledge (not independently source-confirmed this session — flagging as
such rather than asserting it), `a_c_*` animal ped models are fixed,
non-componentized single meshes with **no equivalent drawable-slot system**
— meaning a vest/harness cannot be a "put on a clothing slot" operation the
way it would be for a human ped; it must be a genuinely separate attached
object via `AttachEntityToEntity`, exactly as §7 already assumes. This
narrows, but does not resolve, the open bone-name question above.

### Community precedent
A commercial "K9 Unit Pack" listing advertises "customizable K9 Vests with
four vest customizations and three patches" — confirms vest/harness variety
is a real, shipped feature in at least one commercial K9 script, but its
actual attachment mechanism (separately attached prop vs. a baked-in addon-
ped-model texture variant) could not be confirmed from its public listing
copy alone (source not independently opened this session). One general
prop-attach-tooling search surfaced a real example call shape,
`AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, 24818), 0.18, -0.08,
-0.10, 0, 0, 190, true, true, false, true, 1, true)` — but bone ID `24818`
in that example is drawn from **human**-ped-attachment tooling context, not
verified to be relevant to any `a_c_*` model. Not treated as a confirmed
animal-bone answer, only as a shape-of-the-call reference.

### Verdict
Native-only-approximation confirmed feasible for the *attachment mechanism*
(`AttachEntityToEntity`, already proven in this codebase). **Real custom
prop assets** are still needed for a purpose-built vest/harness/camera-
housing model (`SPEC.md` §7's existing conclusion stands, unchanged, unless
an existing GTA prop is deemed close enough as a placeholder). **The bone-
name/attachment-point question is a genuine open item**, not previously
flagged this precisely anywhere in this codebase.

### Open questions
- Confirm actual usable bone names/indices per configured breed via
  in-engine testing — no source this session could resolve it.
- Whether "tracking camera" (a `PropAttachments` sub-item) is meant purely
  cosmetically or is meant to interact with `CameraFeedPiP` (§6 below) —
  §6.7's wording lists it only as a cosmetic attach; not addressed as a
  functional link either way.

---

## 4. FetchMechanic (`Config.Features.FetchMechanic`)

### What this needs to do
`SPEC.md` §6.7: "dog can pick up, carry (attached to mouth bone), and drop a
physics prop (e.g. the existing `prop_tennis_ball` game asset, or a
designated evidence-bag prop) on a handler command."

### Confirmed natives
| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `CREATE_OBJECT` | `0x509D5878EB39E842` / alt `0x2F7AA05C` | OBJECT | `Object CREATE_OBJECT(Hash modelHash, float x, float y, float z, BOOL isNetwork, BOOL netMissionEntity, BOOL doorFlag)` — spawns the ball/evidence-bag prop; model must already be loaded. |
| `APPLY_FORCE_TO_ENTITY` | (not independently re-verified this pass; already a standard, long-established native used elsewhere in the ecosystem for a "throw" impulse — see community precedent below) | ENTITY | Used by the one confirmed source this session to give the thrown ball its initial velocity/arc. |
| `ATTACH_ENTITY_TO_ENTITY` | `0x6B9BBD38AB0796DF` / alt `0xEC024237` | ENTITY | For a literal mouth-bone carry, per §6.7's own wording — see the bone-name caveat in item 3 above; same unresolved-bone-name status applies here (a mouth/jaw bone name, not a vest/back bone name, but the same "no confirmed animal-skeleton bone name this session" gap). |
| `TASK_GO_TO_COORD_ANY_MEANS` | not independently re-verified this pass (long-established, common native) | TASK | Confirmed in real use (see below) for having a dog-model ped path to the thrown prop's landing position. |
| `NETWORK_REQUEST_CONTROL_OF_ENTITY` | `0xB69317BF5E782347` | NETWORK | Already confirmed in `phase3_combat_natives.md` — needed before the K9's own client can reliably attach a ball prop it doesn't already own network control of, if the ball was created/thrown from a different client (e.g. the handler's). |

### Community precedent — real, source-confirmed, and it reveals a real gap in the codebase's own spec ambition
`fruitmob/murderface-pets` (an open-source, Qbox/ox-stack FiveM pet
companion resource — architecturally an **NPC-controlled pet the resource
spawns and commands**, not a player-controlled character like `qbx_k9unit`'s
K9) has a genuine, source-read fetch implementation in `client/client.lua`:

```lua
lib.requestModel(`prop_tennis_ball`)
local ball = CreateObject(`prop_tennis_ball`, playerPos.x, playerPos.y, playerPos.z + 1.5, true, true, false)
ApplyForceToEntity(ball, 1, forward.x * 12.0, forward.y * 12.0, 6.0, ...)
-- ...
TaskGoToCoordAnyMeans(ped, ballPos.x, ballPos.y, ballPos.z, 5.0, 0, 0, 0, 0)
-- ball is then DeleteEntity(ball)'d, and a pickup *animation* plays —
-- the ball is never actually bone-attached to the pet.
```
Source: `raw.githubusercontent.com/fruitmob/murderface-pets` (`client/client.lua`,
`config.lua` — both read directly this session, not just README copy).
`prop_tennis_ball` as the ball model is independently confirmed real by this
same source's config default.

**This is directly relevant to `SPEC.md` §6.7's own wording, and worth
flagging plainly:** the one concrete, source-confirmed community precedent
found this session for "dog fetches a ball" **does not actually attach the
ball to the pet at all** — it deletes the world object and fakes the
"carry" with an animation. This is a real, working, shipped shortcut around
exactly the harder half of what §6.7 asks for ("carry (attached to mouth
bone)"). It doesn't prove a real mouth-bone attach is infeasible — the
underlying `AttachEntityToEntity` mechanism is confirmed real and working
elsewhere in this exact codebase — but it is evidence that **the one
community implementation found chose not to solve the bone-attach problem**,
which should raise (not lower) the confidence bar around treating "carry
attached to the mouth" as a routine, already-solved detail versus a real
open implementation question (the same bone-name gap flagged in item 3).

**Also worth noting, since `qbx_k9unit`'s K9 is a real player, not an NPC:**
`murderface-pets`' whole architecture (`TaskGoToCoordAnyMeans`,
`TaskFollowTargetedPlayer`) assumes the resource has full AI/task authority
over its own pet ped — this doesn't transfer to a player-controlled K9 the
way it would for an NPC. A player-controlled K9's "fetch" would need the K9
player to walk to the ball themselves (their own input, not a scripted task)
and interact with it via an ox_target/keybind prompt, closer to Phase 1's
existing self-administered pattern (K9 vehicle entry, `client/vehicle.lua`)
than to `murderface-pets`' NPC-task pattern. This is a real architectural
translation, not a drop-in port of the precedent above — flagging per this
project's own "know the architecture gap before assuming a pattern
transfers" discipline (`phase3_combat_patterns.md`'s headline finding made
the identical point about NPC-vs-player-controlled K9 scripts for combat).

### Verdict
Prop spawn/throw/pursue is native-only and has a real, source-confirmed
precedent (spawn, force-impulse throw, task-based approach). The literal
"carried, attached to the mouth bone" half of §6.7's wording is **not**
demonstrated as solved anywhere found this session — same open bone-name
question as item 3, plus a real architecture translation cost (player-input-
driven, not task-driven) that the one concrete precedent found doesn't need
to solve because it's an NPC pet. `prop_tennis_ball` is confirmed as a real,
available vanilla prop either way, and an "evidence-bag prop" alternative
per §7 would need its own custom model unless an existing close-enough GTA
prop is identified (not attempted this session).

### Open questions
- Does the ball actually need to be bone-attached during the "carry back"
  leg, or would this project accept `murderface-pets`' delete-and-animate
  shortcut as good-enough for Phase 5's own bar? Not decided here — a
  real scope/fidelity call for whoever specs this, now backed by a concrete
  precedent to weigh instead of an assumption.
- Exact mouth/jaw bone name for each `Config.Peds` model — unresolved, same
  as item 3's vest/harness bone question, needs the same in-engine dump.

---

## 5. DeployableKennel (`Config.Features.DeployableKennel`)

### What this needs to do
`SPEC.md` §6.7 / §6.6: handler places a world or vehicle-mounted kennel
object; the K9 heals at an accelerated (configurable) rate while resting
inside its radius (ties into Phase 4's fatigue/vitality system — "recovers
over time faster near a water bowl item or a deployable kennel... than
passively," §6.6).

### Confirmed natives
| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `CREATE_OBJECT` | `0x509D5878EB39E842` / alt `0x2F7AA05C` | OBJECT | (as above) |
| `PLACE_OBJECT_ON_GROUND_PROPERLY` | `0x58A850EAEE20FAA3` / alt `0x8F95A20B` | OBJECT | `BOOL PLACE_OBJECT_ON_GROUND_PROPERLY(Object object)` — "positions an object on the ground with proper collision handling," returns success/fail. Real, confirmed native for the placement step. |
| `FREEZE_ENTITY_POSITION` | `0x428CA6DBD1094446` / alt `0x65C16D57` | ENTITY | `void FREEZE_ENTITY_POSITION(Entity entity, BOOL toggle)` — "Freezes... preventing coordinate changes by the player... position can still be modified using `SET_ENTITY_COORDS`." For pinning the placed kennel in place after placement, same pattern this codebase's own `client/vehicle.lua` already uses for a different entity (`FreezeEntityPosition(ped, true)`). |
| `GET_ENTITY_HEALTH` / `SET_ENTITY_HEALTH` | not independently re-verified this pass (`GetEntityHealth` already established in this codebase's own `phase2_notes/phase4_hud_bridge_design.md` for the HUD's health readout) | ENTITY | For applying the accelerated regen tick while the K9 is in-radius — no new native needed, this is a straightforward extension of a pattern already planned for Phase 4. |

### The prop-model question — one real, plausible, single-source lead found; not independently cross-verified
`fruitmob/murderface-pets` (same source read for item 4) has a **deployable
doghouse feature already shipped** (`client/doghouse.lua`), for a different
purpose (a breeding "rest bonus," not K9-specific healing, but the exact
same underlying "place a world object → proximity radius → passive-stat
bonus" shape `SPEC.md` §6.6/§6.7 describes for the kennel). Its config
default:
```lua
propModel = 'prop_doghouse_01',
restBonusRadius = 15.0,
placementMaxDistance = 50.0,
```
Source: `raw.githubusercontent.com/fruitmob/murderface-pets` (`config.lua`,
read directly). **This is a real, plausible lead for a vanilla GTA doghouse
prop model existing (`prop_doghouse_01`)** — but it could **not** be
independently cross-verified against a second source this session
(`gtax.dev` and `gtahash.com`, the two purpose-built prop-name databases
that would normally corroborate a model-name claim, are both blocked by
this environment's egress proxy; a GTA Wiki "Doghouse" page that plausibly
covers Franklin's aunt Denise's story-mode doghouse was also blocked).
Per this project's established confidence convention (two-independent-
source standard from `phase3_combat_natives.md`'s Rottweiler-clip finding),
**this is a single-source, plausible-but-unconfirmed lead, not a
verified fact** — flag it to whoever implements this as "try
`prop_doghouse_01` first, confirm it loads in-engine," not as a settled
answer.

Placement/config shape worth reusing regardless of the exact prop name:
`murderface-pets`' doghouse placement flow (load model →
`CreateObjectNoOffset` at a raycast-guided offset → player-controlled
rotate/confirm/cancel via keybinds → `PlaceObjectOnGroundProperly` →
`FreezeEntityPosition`) is a real, working, source-confirmed placement UX
pattern directly transferable to a kennel placed by a handler, independent
of whether the exact prop-name lead above pans out.

### Verdict
Mechanically native-only and fully achievable (placement, freeze,
proximity-radius healing tick) — no native gap of any kind. The custom-
asset question `SPEC.md` §7 already flagged as "unconfirmed whether GTA
ships one natively" is **narrowed but not closed**: one plausible vanilla
prop name (`prop_doghouse_01`) was found via a single, unconfirmed-cross-
referenced community source, worth an in-engine load test before committing
to it, not worth treating as confirmed. If it turns out not to exist or not
to be the model this session's source implies, an existing GTA prop
(e.g. a generic shed/container/pallet-style prop) as a stand-in, or a
custom-modeled kennel, remain the fallback options `SPEC.md` §7 already
names.

### Open questions
- Confirm `prop_doghouse_01` actually exists and streams correctly
  in-engine — single-source lead, not verified.
- Whether "vehicle-mounted kennel" (the other half of §6.7's wording,
  alongside "world" kennel) needs a distinct attach-to-vehicle-bone
  mechanism (same `AttachEntityToEntity`-to-a-vehicle-bone pattern as
  `client/vehicle.lua`'s existing K9-in-vehicle attach) or a separate
  vehicle-specific prop — not addressed by any source found this session,
  a real scope question for whoever specs this.

---

## 6. CameraFeedPiP (`Config.Features.CameraFeedPiP`) — flagged by `SPEC.md` §7/§9 as the most speculative item

### What `SPEC.md` already says (read before researching, per process)
§7 already concludes: a full-screen camera **takeover** (not true
picture-in-picture) via `CreateCam`/`RenderScriptCams` is achievable
native-only; a genuine **inset** live-3D-video PiP is *not* achievable with
stock natives because "DUI/NUI textures render HTML, not the 3D scene;
there's no native 'camera → runtime texture' hook in stock natives." §9 item
6 explicitly asks for this session's kind of pass to produce "a definitive
yes/no." §2's non-goals list already states true PiP video is out of scope
this pass regardless of the spike's outcome being scheduled as future work.

### This session's research directly and independently corroborates that conclusion — nothing found contradicts it
- **A live, open, unresolved upstream issue on `citizenfx/fivem` itself**
  (`GitHub issue #3835`, title: "Documentation Improvement: Secondary
  Camera / PiP Render Target Native for NUI (Feature Context: live 3D feed
  overlays)") **confirms this is presently a documentation/feature gap, not
  a shipped, documented capability** — read directly this session: it is a
  request asking Cfx for "existing and expected natives/API" for "secondary
  cameras and render their output to a D3D texture shareable to NUI" for
  exactly this "CCTV/PiP" use case, filed as a "Nice extra"-priority ask,
  with **no specific native names cited by the requester either**, meaning
  even the person asking couldn't point to a working native path. This is
  independent, primary-source confirmation (not a search-engine snippet)
  that no established, documented native mechanism for this exists as of
  this session.
- **Every real camera implementation found this session is a full-screen
  takeover, none are an inset.** `ice-mineman/FiveM-Dashcam` (open source,
  read directly): `CreateCam('DEFAULT_SCRIPTED_CAMERA', 1)` →
  `RenderScriptCams(1, 0, 0, 1, 1)` fully replaces the player's screen with
  the dashcam view; any telemetry overlay is a flat NUI layer drawn *over*
  that full-screen camera takeover, not a separate live-video inset. This
  independently confirms `RenderScriptCams`' documented behavior
  ("renders the camera previously created with `CreateCam`") is a full
  view-replacement mechanism, matching `SPEC.md` §7's own framing exactly.
- No CCTV/security-camera FiveM script's actual rendering technique
  (DUI/NUI vs. render-target-on-a-prop-texture vs. full-screen switch)
  could be confirmed from source this session — every CCTV script found
  (`apx-studios/astudios-cctv`, various commercial listings) only exposed
  marketing/feature copy, not a technical implementation detail, through
  the tooling available. **This is a real gap in this session's research,
  not a negative finding** — it's possible one of these commercial products
  has solved a genuine inset view some other way (e.g. a literal full-
  screen "camera view" opened in a separate context, not a true inset;
  or a scaleform/quad-view trick not surfaced by the queries run) — flagging
  as unconfirmed rather than asserting a stronger negative than the evidence
  supports.

### Confirmed natives (for whichever version — takeover or spike-only — gets built)
| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `CREATE_CAM` | `0xC3981DCE61D9E13F` / alt `0xE9BF2A7D` | CAM | `Cam CREATE_CAM(char* camName, BOOL active)` — doc text: "won't display until you invoke `RENDER_SCRIPT_CAMS`." |
| `RENDER_SCRIPT_CAMS` | `0x07E5B515DB0636FC` / alt `0x74337969` | CAM | `void RENDER_SCRIPT_CAMS(BOOL render, BOOL ease, int easeTime, BOOL easeCoordsAnim, BOOL p4)` — confirmed full-view-replacement behavior, not an inset, both by doc text and by the `FiveM-Dashcam` source read this session. |
| `SET_CAM_COORD` / `SET_CAM_ROT` / `SET_FOCUS_ENTITY` / `DESTROY_CAM` | not independently re-verified this pass (standard, long-established CAM-namespace natives, already confirmed in real use by the `FiveM-Dashcam` source read this session) | CAM | Positioning/cleanup for whatever camera entity the K9's own point of view would use for the takeover spike. |

### Verdict — unchanged from `SPEC.md` §7, now independently corroborated rather than asserted from first principles
**No native-only true PiP path exists.** This session found a live upstream
Cfx issue confirming the gap is real and currently unresolved (not merely
undocumented-but-secretly-possible), plus a source-read confirmation that
every real "camera view" script in this ecosystem does a full-screen
takeover, none an inset. §7's committed Phase 5 deliverable (a feasibility
*spike* producing a full-screen K9-POV takeover toggle, explicitly not a
real PiP) remains the correct, buildable scope. Nothing found this session
argues for attempting more than that spike, and nothing found argues the
spike itself is at risk — `CreateCam`/`RenderScriptCams` are real, confirmed,
already-precedented (dashcam scripts) natives fully sufficient for exactly
that scoped deliverable.

### Community precedent
**Full-screen takeover: yes, real, source-confirmed** (`FiveM-Dashcam`).
**True inset PiP of a live 3D camera feed: no shipped, technically-confirmed
FiveM resource was found this session** — several commercial CCTV/security-
camera products *market* a "live monitoring" feature, but none could be
confirmed (from source) to be doing more than a full-screen camera switch
or a similarly-scoped alternative; this is recorded as "not found," not
"confirmed not to exist anywhere," given the closed-source nature of most
of those listings.

### Open questions
- Whether any of the several commercial CCTV scripts found this session
  (`apx-studios/astudios-cctv`, listings referenced in a `forum.cfx.re`
  thread that is itself blocked from this environment) have a real
  technical trick beyond full-screen takeover — genuinely unresolved, would
  need either direct access to a purchased product's source or an
  unblocked path to `forum.cfx.re` to chase further.
- Whether the upstream Cfx issue (#3835) sees any movement (it's an open,
  unresolved ask as of this session) — worth a periodic re-check by
  whoever eventually revisits this spike, since a future Cfx platform
  addition could change this verdict; not something to assume will happen.

---

## Summary table

| Feature | Native-only mechanism confirmed? | Real asset needed? | Community precedent | Confidence |
|---|---|---|---|---|
| AdvancedBarkRadial | Yes (`PlaySoundFromEntity`, already in use) | **Yes — multiplies Phase 1's existing accepted bark-audio gap** (3x real `.awc`/REL-authored soundsets, not just 3 files) | None found for multi-type bark sourcing | High on natives, none on precedent |
| ProximityAudioFX | Yes for baseline distance falloff; scripted logic (not a single native) for the "attenuate toward a hidden suspect" gameplay hook | No new asset if using discrete distance-tier clips reusing item 1's assets | **None found** — likely novel for this niche | High on natives, none on precedent |
| PropAttachments | Yes for the attach mechanism (`AttachEntityToEntity`, already proven in this codebase) | Yes — purpose-built vest/harness/camera-housing prop; bone name unresolved | One commercial listing (unconfirmed mechanism), one human-bone-ID example (not confirmed relevant to animal peds) | Medium — bone-name gap unresolved |
| FetchMechanic | Yes for spawn/throw/pursue (source-confirmed); mouth-bone carry-attach unconfirmed anywhere | `prop_tennis_ball` confirmed real and free; evidence-bag prop would need custom asset | **Real, source-read precedent found — and it skips the hardest part** (deletes+animates rather than bone-attaching) | High on throw mechanic, open on carry-attach |
| DeployableKennel | Yes, fully (placement/freeze/regen-tick) | Possibly not — one single-source, unverified lead (`prop_doghouse_01`) | Real, source-read precedent for the placement UX and the proximity-bonus shape (different resource, same pattern) | High on mechanism, low-confidence single-source on the prop name |
| CameraFeedPiP | Full-screen takeover: yes, confirmed. True inset PiP: **no** | N/A for the takeover spike; true PiP would need a Cfx platform capability that does not currently exist | Full-screen takeover confirmed real and shipped (dashcam scripts); true inset PiP: none found, and an open upstream Cfx issue independently confirms the gap | High — corroborates `SPEC.md` §7 rather than changing it |

---

## Sources

- [PlaySoundFromEntity.md](https://github.com/citizenfx/natives/blob/master/AUDIO/PlaySoundFromEntity.md)
- [SetVariableOnSound.md](https://github.com/citizenfx/natives/blob/master/AUDIO/SetVariableOnSound.md)
- [RequestScriptAudioBank.md](https://github.com/citizenfx/natives/blob/master/AUDIO/RequestScriptAudioBank.md)
- [GetPedBoneIndex.md](https://github.com/citizenfx/natives/blob/master/PED/GetPedBoneIndex.md)
- [GetEntityBoneIndexByName.md](https://github.com/citizenfx/natives/blob/master/ENTITY/GetEntityBoneIndexByName.md)
- [AttachEntityToEntity.md](https://github.com/citizenfx/natives/blob/master/ENTITY/AttachEntityToEntity.md) (already cited in `phase3_combat_natives.md`)
- [CreateObject.md](https://github.com/citizenfx/natives/blob/master/OBJECT/CreateObject.md)
- [PlaceObjectOnGroundProperly.md](https://github.com/citizenfx/natives/blob/master/OBJECT/PlaceObjectOnGroundProperly.md)
- [FreezeEntityPosition.md](https://github.com/citizenfx/natives/blob/master/ENTITY/FreezeEntityPosition.md)
- [CreateCam.md](https://github.com/citizenfx/natives/blob/master/CAM/CreateCam.md)
- [RenderScriptCams.md](https://github.com/citizenfx/natives/blob/master/CAM/RenderScriptCams.md)
- [citizenfx/fivem issue #3835 — Secondary Camera / PiP Render Target Native for NUI](https://github.com/citizenfx/fivem/issues/3835) (read directly this session; primary-source confirmation of the doc/feature gap)
- [fruitmob/murderface-pets](https://github.com/fruitmob/murderface-pets) — `client/client.lua` (fetch mechanic) and `config.lua` (doghouse prop default, fetch emote definition) read directly via raw source fetch this session
- [ice-mineman/FiveM-Dashcam](https://github.com/ice-mineman/FiveM-Dashcam) — `client.lua` read directly this session (full-screen camera takeover confirmation)
- [Walsheyy/WMServerSirens](https://github.com/Walsheyy/WMServerSirens) — README referenced via search for the `.awc`/`dat151`/`dat54` custom-soundset authoring pipeline claim (not independently cross-verified against a second explainer)
- This codebase's own `client/main.lua` (bark placeholder, already-documented asset gap), `client/vehicle.lua` (`AttachEntityToEntity`/`FreezeEntityPosition` real in-repo precedent), and `phase2_notes/phase4_hud_bridge_design.md` (`GetEntityHealth` precedent)
- Search-engine-indexed, not independently source-confirmed this session (flagged inline above, not presented as verified): a commercial "K9 Unit Pack" vest-customization listing, a human-ped-bone-attach tooling example (`GetPedBoneIndex(ped, 24818)`), commercial CCTV script listings (`apx-studios/astudios-cctv`, others)

Note: as with every prior `phase2_notes/*_natives.md`/`*_patterns.md` file
in this codebase, `docs.fivem.net` itself could not be reached directly this
session (`EGRESS_BLOCKED`) — all native hash/signature claims above trace to
`raw.githubusercontent.com/citizenfx/natives`, the same upstream source
`docs.fivem.net` is generated from. `gtaforums.com`, `gta.fandom.com`,
`gtax.dev`, `gtahash.com`, and `forum.cfx.re` were also blocked this
session, which is why several leads above (the animal-bone-access GTAForums
thread, the doghouse prop cross-reference, several CCTV product deep-dives)
are recorded as single-source or unconfirmed rather than resolved.
