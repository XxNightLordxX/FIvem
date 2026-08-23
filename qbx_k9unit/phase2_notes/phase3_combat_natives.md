# Phase 3 native verification — Bite-and-Hold, Non-Lethal Takedown, Handler-Down Defense, Prop Dragging, Advanced Agility

Status: pure native-verification pass against `PHASE3_SPEC.md` §12.5.1-§12.5.5's
explicitly-flagged "not verified this session" items and §7's own
native-only-approximation table. **Design forks (§12.0 items 1-4, and
§12.5.5's raycast-vs-tagged-prop fork) are NOT re-litigated here** — those
are product/security decisions, not native-availability questions, per this
task's own scope. This note only closes native-verification gaps;
`PHASE3_SPEC.md` itself is read-only in this pass (not edited).

**Network note (same as every prior `phase2_notes/*_natives.md` file):**
`docs.fivem.net`, `runtime.fivem.net`, `forum.cfx.re`, `forge.plebmasters.de`,
and `www.gta5-mods.com` are all blocked by this environment's egress proxy
(confirmed again this session — direct `WebFetch` to `docs.fivem.net`
returned `EGRESS_BLOCKED`). Verification below uses
`raw.githubusercontent.com/citizenfx/natives` directly (the same canonical
upstream source `docs.fivem.net` itself renders from) for every native
hash/signature, plus targeted `WebSearch` for anim-dictionary/clip
corroboration where no natives-repo page applies (animations aren't
natives, they're game data, so there's no equivalent canonical repo page —
flagged per-item below where a source is one-notch-removed for that reason,
not because the native lookup itself was unavailable).

---

## 1. Bite-and-Hold (`Config.Features.BiteAndHold`, `PHASE3_SPEC.md` §12.5.1)

### Confirmed natives (mechanical side — control-disable/AI-suppression "hold", not the bite itself)

| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `TASK_PLAY_ANIM` | `0xEA47FE3719165B94` / alt `0x5AB552C6` | TASK | `void TASK_PLAY_ANIM(Ped ped, char* animDictionary, char* animationName, float blendInSpeed, float blendOutSpeed, int duration, int flag, float playbackRate, BOOL lockX, BOOL lockY, BOOL lockZ)` |
| `SET_BLOCKING_OF_NON_TEMPORARY_EVENTS` | `0x9F8AA94D6D97DBF4` | PED | `void SET_BLOCKING_OF_NON_TEMPORARY_EVENTS(Ped ped, BOOL toggle)` — doc text: "works with TASK::TASK_SET_BLOCKING_OF_NON_TEMPORARY_EVENTS to make a ped completely oblivious to all events going on around him." Confirmed real, correct native for suppressing an NPC target's own AI reactions during a hold, exactly as `PHASE3_SPEC.md` §12.5.1 names it. |
| `SET_PED_FLEE_ATTRIBUTES` | `0x70A2D1137C8ED7C9` / alt `0xA717A875` | PED | `void SET_PED_FLEE_ATTRIBUTES(Ped ped, int attributeFlags, BOOL enable)` — confirmed real; also named correctly in §12.5.1. |
| `NETWORK_REQUEST_CONTROL_OF_ENTITY` | `0xB69317BF5E782347` | NETWORK | `BOOL NETWORK_REQUEST_CONTROL_OF_ENTITY(Entity entity)` — needed before an NPC-target client can reliably drive `SetBlockingOfNonTemporaryEvents`/`SetPedFleeAttributes`/`AttachEntityToEntity` on an entity it doesn't already own network control of. Not named explicitly in §12.5.1's text but is the correct prerequisite native for the NPC-target path §12.0 item 1 describes. |
| `ATTACH_ENTITY_TO_ENTITY` | `0x6B9BBD38AB0796DF` / alt `0xEC024237` | ENTITY | `void ATTACH_ENTITY_TO_ENTITY(Entity entity1, Entity entity2, int boneIndex, float xPos, float yPos, float zPos, float xRot, float yRot, float zRot, BOOL p9, BOOL useSoftPinning, BOOL collision, BOOL isPed, int rotationOrder, BOOL syncRot)` — this codebase's own established pattern for "cosmetic near-attachment, not a rigid bite" (already used this way in `client/vehicle.lua`'s vehicle load-in, e.g. `AttachEntityToEntity(ped, vehicle, 0, 0.0, -1.5, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)`). Confirms `SPEC.md` §7's existing framing ("attached near the target's arm/torso... no rigid physical bone attachment") is a real, achievable native pattern, not hand-waving. |
| `DETACH_ENTITY` | `0x961AC54BF0613F5D` / alt `0xC8EFCB41` | ENTITY | `void DETACH_ENTITY(Entity entity, BOOL dynamic, BOOL collision)` — for Release/Recall/timeout cleanup, mirrors `client/movement.lua`'s existing `ReleasePedFromVehicleState`'s own `DetachEntity(ped, true, false)` call shape. |

### The bite/attack anim question — PARTIALLY RESOLVED, not fully

`PHASE3_SPEC.md` §12.5.1 explicitly flags this as "not previously verified
anywhere in this codebase... this was not verified this session — flag it
honestly as unresolved, not as a confirmed asset." Updating that status:

**A real anim dictionary/clip pair was found, but it is a one-shot
takedown pose, not a sustained bite-and-hold loop — do not read this as
fully resolving the open question, only narrowing it.**

- `creatures@rottweiler@melee@streamed_core@` / `takedown_from_back` (with a
  paired `takedown_from_back_facial` face-layer clip of the same name) is a
  real, dated game asset — indexed by Pleb Masters: Forge's animation
  data-browser (a decompiled-game-data-derived source, the same class of
  source `client/movement.lua`'s own Sit-scenario header already accepts as
  "independently maintained community scenario dumps... decompiled-game-data-
  derived," though here from a single source, not two independently
  agreeing ones the way Sit's `WORLD_DOG_SITTING_*` finding was). Search
  results additionally surfaced a release-date attribution ("Patchday 2ng,"
  October 2014) consistent with a real shipped asset, not a fabricated
  name.
- **Confidence: MEDIUM, one-notch-removed.** `forge.plebmasters.de` itself is
  blocked by this environment's egress proxy (same as `docs.fivem.net`), so
  this could not be opened directly to browse sibling clips in the same
  `creatures@rottweiler@melee@streamed_core@` dictionary (there may be more
  than just `takedown_from_back` in there — an "attack_final," "bite_loop,"
  or similar sustained-hold clip could exist alongside it and simply wasn't
  surfaced by the specific search queries run this session). Confirmation
  here rests on search-engine-indexed page titles/URLs from that site (the
  URL path itself literally encodes dict@clip, which is how Forge structures
  its real, data-derived animation browser) rather than a directly fetched
  page — **weaker corroboration than the two-independent-source standard
  `client/movement.lua`'s Sit scenario met**, so treat this as a real lead
  worth an in-engine `TaskPlayAnim` test, not a shipped-confidence fact.
- **This clip is model-specific to `a_c_rottweiler`** (Chop's model) the
  same way `WORLD_DOG_SITTING_ROTTWEILER` is — `Config.Peds`' other
  configured breeds (shepherd, retriever/huskie per `client/movement.lua`'s
  own `K9_SIT_SCENARIO_BY_MODEL_HASH` mapping) have **no equivalent
  melee/takedown clip confirmed this session at all** — not even a
  medium-confidence guess. Any implementation needs either a
  per-breed fallback table (same shape as the Sit scenario's own
  `K9_SIT_DEFAULT_SCENARIO` fallback) or an explicit decision to fall back
  to a **non-model-specific generic approach** (see recommendation below)
  for non-Rottweiler breeds.
- **A one-shot pose is not the same shape as "held... until Recall/timeout."**
  `takedown_from_back` almost certainly plays once (a lunge/knockdown pose,
  the kind of thing consistent with the wild-dog ambient attack event or a
  scripted stealth-takedown reuse), not a loopable "latched onto the target's
  arm, straining" idle. `TASK_PLAY_ANIM`'s own `duration` parameter (-1 for
  indefinite) can force any clip to hold on its last frame indefinitely, so
  it's technically usable as a static held-pose placeholder for the hold
  duration, but that is very likely to look wrong in-engine (a frozen
  takedown-lunge pose held for up to 15 seconds) — this needs actual
  in-engine testing before being treated as acceptable, not assumed fine
  from the clip name alone.
- **No confirmed sustained "bite and hold" idle/loop animation was found for
  any breed this session.** The honest options, none fully satisfying:
  (a) play `takedown_from_back` once for the initial lunge, then hold a
  generic aggressive-stance scenario (`WORLD_DOG_BARKING_*`, already
  confirmed real by `client/movement.lua`'s own Sit-scenario research) as
  the sustained "holding" visual — a barking loop is not a bite pose, but it
  is a real, confirmed, in-scope asset that at least visually reads as
  "aggressive," unlike freezing a takedown pose; (b) skip a per-breed anim
  entirely and represent "held" purely as the control-disable/AI-suppression
  mechanical state with no distinct dog-side animation beyond the initial
  lunge — matches `SPEC.md` §7's own baseline framing ("a task/animation
  state on the dog plus a control-disable flag on the target," which doesn't
  strictly require a *sustained* animation); (c) accept the frozen-pose
  option above pending in-engine visual review. **Not decided here** — this
  is a design/asset call for coder-frontend once someone has direct game
  access to actually preview `takedown_from_back` in motion, not something
  resolvable from documentation alone.

### Verdict: native-only-approximation for the MECHANICAL hold, ASSET-GAP-NARROWED (not closed) for the animation

Matches `SPEC.md` §7's existing conclusion for the mechanical side exactly:
control-disable + AI-suppression natives are fully confirmed, real,
zero-new-asset. The animation side is no longer a total unknown — a real
takedown clip exists for at least the Rottweiler model — but it is not a
drop-in "bite and hold" loop, doesn't cover every configured breed, and its
in-motion quality is unverified from documentation alone. **Recommend:
before implementation, someone with direct FiveM client access previews
`TaskPlayAnim(ped, 'creatures@rottweiler@melee@streamed_core@',
'takedown_from_back', ...)` in-engine** — this is the single highest-value
next verification step this note can identify but cannot itself perform.

### Player-target self-suppress (only relevant if §12.0 item 1 puts players in scope)
`DISABLE_CONTROL_ACTION` — already a confirmed, established native in this
codebase (`client/movement.lua`'s own `AgilityBasicJump` suppression thread
uses it identically). No new verification needed; same native, same
per-frame-reassertion contract, just gating sprint (`INPUT_SPRINT` = 21) and
fire (`INPUT_ATTACK` = 24, `INPUT_VEH_ATTACK` etc. if a vehicle-mounted case
is ever in scope) controls instead of jump/duck.

---

## 2. Non-Lethal Takedown (`Config.Features.NonLethalTakedown`, `PHASE3_SPEC.md` §12.5.2)

### Confirmed natives

| Native | Hash | Namespace | Signature | Notes |
|---|---|---|---|---|
| `SET_PED_TO_RAGDOLL` | `0xAE99FB955581844A` / alt `0x83CB5052` | PED | `BOOL SET_PED_TO_RAGDOLL(Ped ped, int minTime, int maxTime, int ragdollType, BOOL bAbortIfInjured, BOOL bAbortIfDead, BOOL bForceScriptControl)` | **This is the real, current native — `TaskRagdollPed` (the name `PHASE3_SPEC.md` §12.5.2's prose informally uses) is not the canonical citizenfx/natives doc name; it does not have its own page in the canonical natives repo.** `ragdollType` 0 = `CTaskNMRelax`, 1 = `CTaskNMScriptControl` (doc note: "hardcoded not to work in networked environments" — **do not use type 1 for a networked takedown**), other = `CTaskNMBalance`. `minTime`/`maxTime` only apply to type 0. This corrects §12.5.2's native name, not its feasibility claim — the underlying claim ("fully native-only... a well-established FiveM pattern") holds. |
| `SET_PED_TO_RAGDOLL_WITH_FALL` | `0xD76632D99E4966C8` / alt `0xFA12E286` | PED | `BOOL SET_PED_TO_RAGDOLL_WITH_FALL(Ped ped, int minTime, int maxTime, int nFallType, float dirX, float dirY, float dirZ, float fGroundHeight, float grab1X, float grab1Y, float grab1Z, float grab2X, float grab2Y, float grab2Z)` | A directional-fall variant of the above — likely a better match than plain `SetPedToRagdoll` for "the K9 knocks the target down" since it takes a fall direction, closer to a real knockdown than a generic limp-ragdoll. Grab-position params are documented as unused. Worth coder-frontend evaluating over the plain variant at implementation time — not a blocking finding, just a better-fit alternative surfaced during this pass. |
| `CAN_PED_RAGDOLL` | `0x128F79EDCECE4FD5` / alt `0xC0EFB7A3` | PED | `BOOL CAN_PED_RAGDOLL(Ped ped)` (name is misleading — doc text: "Prevents the ped from going limp," i.e. this is a **setter/blocker**, not a pure query, despite reading like an `Is*`-style boolean check) | Relevant defensively: if some other resource on the target server has already set a ped/player to never-ragdoll (e.g. an anti-ragdoll admin tool), a forced `SetPedToRagdoll` call may silently do nothing — worth a defensive check, not previously mentioned in `PHASE3_SPEC.md`. |
| `IS_PED_RAGDOLL` | `0x47E4E977581C5B55` / alt `0xC833BBE1` | PED | `BOOL IS_PED_RAGDOLL(Ped ped)` | Useful for server/client-side "is the takedown still in effect" polling without needing a separate timer if the ragdoll state itself is treated as the authority for "still down." |

### The fall-damage-suppression native question — RESOLVED: no dedicated native exists; here is the real alternative

`PHASE3_SPEC.md` §12.5.2 flags this explicitly: "the fall-damage-immunity
flag/native needs its own verification pass (not attempted this session)."
Resolving it now:

- **No dedicated "suppress fall damage specifically" native or
  `SetPedConfigFlag` flag ID was confirmed to exist.** Searches for a named
  ped-config flag (`SET_PED_CONFIG_FLAG`, hash `0x9CFBE10D`, confirmed real
  as a native in general — it's the standard mechanism for dozens of
  documented ped behavior toggles) turned up only *observational* data (a
  GTAForums community flag-dump noting flags 60/61/104/276 "change to
  FALSE" and flag 76 "changes to TRUE" while a ped is actually falling) —
  these read as **side-effect observations of the falling state changing
  those flags' values**, not a documented "set this flag to suppress fall
  damage" control surface. I'm not confident enough in that flag-dump's
  interpretation to hand it to coder-backend as a real API — flagging it as
  found-but-unusable rather than fabricating a specific flag ID/meaning from
  it.
- **The real, confirmed, native-only mechanism to guarantee no damage from
  a forced ragdoll is `SET_ENTITY_CAN_BE_DAMAGED`** (hash
  `0x1760FFA8AB074D66` / alt `0x60B6E744`, namespace ENTITY, signature
  `void SET_ENTITY_CAN_BE_DAMAGED(Entity entity, BOOL toggle)`), bracketing
  the forced-ragdoll window: `SetEntityCanBeDamaged(target, false)`
  immediately before `SetPedToRagdoll`/`SetPedToRagdollWithFall`, then
  `SetEntityCanBeDamaged(target, true)` on hold-end/timeout. This is
  **broader than fall-damage-specific** — it blocks *all* damage sources
  during the window (bullets, melee, further fall impact, everything), not
  just fall damage — but it is a real, confirmed native and it directly
  satisfies §12.5.2's actual requirement ("without applying lethal
  damage... a floor alone doesn't explain, in-fiction, why an already-low-
  health target being knocked down repeatedly never actually dies from the
  fall itself"). Given `Config.Combat.NonLethalTakedown.healthFloor` is
  already documented as a backstop rather than the primary mechanism, using
  a temporary blanket damage-block for the ragdoll window is arguably a
  *more* robust primary mechanism than a narrower fall-damage-only flag
  would have been, not a downgrade.
- **`SET_ENTITY_INVINCIBLE`** (hash `0x3882114BDE571AD4` / alt
  `0xC1213A21`, `void SET_ENTITY_INVINCIBLE(Entity entity, BOOL toggle)`)
  was also checked as a candidate and is **not recommended for this specific
  use** — its own doc text states "Peds will not ragdoll on explosions,"
  meaning full invincibility has a documented side effect of suppressing
  ragdoll reactions in at least one damage-source case. Since the entire
  point of this feature is to force a visible ragdoll, stacking
  invincibility (which may fight the ragdoll visual itself) is a real risk
  `SetEntityCanBeDamaged` doesn't share — `SetEntityCanBeDamaged` only gates
  the *damage/health* pipeline, not ragdoll physics reactions, making it the
  better-fit primitive here.
- **Ordering, per §12.5.2's own already-correct instinct:** call
  `SetEntityCanBeDamaged(target, false)` and apply the health floor **before**
  triggering the ragdoll task, exactly as §12.5.2 already specifies for the
  health-floor ordering — now with a concrete, confirmed native to pair with
  that ordering discipline instead of a TBD placeholder.

### Verdict: fully native-only, zero new asset — same conclusion as `PHASE3_SPEC.md`, now with the fall-damage gap closed

No asset gap of any kind here (unlike Bite-and-Hold). The one previously-TBD
native question is resolved: use `SetEntityCanBeDamaged` bracketing, not a
fall-damage-specific flag (none confirmed to exist), with
`SetPedToRagdollWithFall` as the recommended ragdoll variant over the plain
`SetPedToRagdoll` §12.5.2's prose implicitly assumed.

---

## 3. Handler-Down Defense (`Config.Features.HandlerDownDefense`, `PHASE3_SPEC.md` §12.5.3)

`PHASE3_SPEC.md` §12.5.3 already concludes, correctly, that **under its own
recommended non-AI-takeover reading, this feature needs no new native
capability beyond what Bite-and-Hold/Non-Lethal-Takedown already require**
— it is a server-triggered UI/targeting convenience layered on top of §1/§2
above, reusing Phase 2's existing `server/tracking.lua` damage-event log
(`CEventNetworkEntityDamage`'s attacker field) rather than any new
ingestion path. **This native-verification pass confirms that framing is
correct and has nothing to add or correct on the native side** — every
native this feature would touch is already covered in §1/§2 above (the
"aggressive state" is UI/target-selection, not a new movement/combat
primitive).

**The one open item here is explicitly a design-posture question, not a
native-availability one** (§12.5.3's own text: "this is the single clearest
place in Phase 3 where a literal reading of `SPEC.md`'s existing text would
violate the project's own already-established non-goal" — i.e. §12.0 item
4's partnership-link fork and the UI-convenience-vs-AI-takeover reading).
Per this task's explicit scope, that is not re-litigated here — it is a
product/security decision, not a native-verification gap. If the
alternative literal "AI takeover" reading is ever actually chosen instead
of the recommended one, that would newly require `TASK_COMBAT_PED` (hash
`0xF166E48407BAC484` / alt `0xCB0D8932`, namespace TASK, signature
`void TASK_COMBAT_PED(Ped ped, Ped targetPed, int p2, int p3)`, doc note:
"p2 should be 0 p3 should be 16") for a fully autonomous ped-vs-ped attack
task — confirmed real and available if that fork is ever resolved the other
way, but not needed under the recommended reading, and noting its existence
here only so it isn't re-discovered from scratch if that design question is
ever revisited.

### Verdict: no native gap — this feature's feasibility is entirely inherited from §1/§2 above, exactly as `PHASE3_SPEC.md` already concluded

---

## 4. Prop Dragging (`Config.Features.PropDragging`, `PHASE3_SPEC.md` §12.5.4)

### Confirmed natives

| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `ATTACH_ENTITY_TO_ENTITY` | `0x6B9BBD38AB0796DF` / alt `0xEC024237` | ENTITY | (full signature in §1 table above) — confirmed, and confirmed already in real use in this exact codebase for an entity-attach case (`client/vehicle.lua`'s vehicle load-in), directly backing §12.5.4's own claim that NPC-target dragging is "no new architecture needed beyond what Phase 1's vehicle-load feature already uses safely." |
| `DETACH_ENTITY` | `0x961AC54BF0613F5D` / alt `0xC8EFCB41` | ENTITY | (full signature in §1 table above) |
| `NETWORK_REQUEST_CONTROL_OF_ENTITY` | `0xB69317BF5E782347` | NETWORK | (full signature in §1 table above) — needed before attaching an NPC ped the K9's own client doesn't already control. |
| `IS_PED_DEAD_OR_DYING` | `0x3317DEDB88C95038` / alt `0xCBDB7739` | PED | `BOOL IS_PED_DEAD_OR_DYING(Ped ped, BOOL checkMeleeDeathFlags)` — doc text: setting `checkMeleeDeathFlags` true additionally counts "peds in the midst of melee takedown moves as being in a dying state, even if the death task has not yet started," which is a genuinely good fit for an NPC "is this ped currently downed from a takedown" check (§12.5.4's own NPC-side approximation suggestion) — worth using `true` here specifically, not just the ped's binary dead/alive state. |
| `IS_PED_RAGDOLL` | `0x47E4E977581C5B55` / alt `0xC833BBE1` | PED | (as above) — the second half of §12.5.4's own suggested NPC "downed" approximation ("a ragdolled-and-not-recovering state after a takedown"). |
| `SET_PED_MOVE_RATE_OVERRIDE` | `0x085BF80FA50A39D1` | PED | `void SET_PED_MOVE_RATE_OVERRIDE(Ped ped, float value)` — doc text explicitly warns this "Needs to be looped!" (i.e. it is **not** a one-shot toggle the way `SetNightvision`/`SetSeethrough` are — Phase 2's `thermal_night_vision_natives.md` finding does NOT generalize here). This is the natural fit for `Config.Combat.PropDragging.dragSpeedMultiplier`, but implementation must re-assert it every tick the drag is active (or every tick the dragged ped exists), not call it once on drag-start — a real, concrete implementation detail this note surfaces that §12.5.4's config sketch doesn't currently call out. |

### The "downed" player-target integration dependency — CONFIRMED as a genuine native-surface gap, not a documentation gap

`PHASE3_SPEC.md` §12.5.4 already correctly concludes there is no generic
native for a scripted incapacitation/laststand state and frames this as an
external-integration dependency, mirroring §11.6's door-lock-state
precedent. This native-verification pass has nothing to add here beyond
confirming the negative: no `Is*Downed`/`Is*Incapacitated`-shaped native
exists in the ENTITY/PED namespaces for this — a targeted look alongside
`IsPedDeadOrDying`/`IsPedRagdoll` above surfaced no third native that
models a scripted "downed but not dead, not literally ragdolled" state,
because that state doesn't exist in vanilla GTA at all (it's entirely a
framework/resource-specific concept, e.g. an EMS/laststand system's own
data). §12.5.4's conclusion stands unmodified: this is a hard external
dependency, not something a deeper native search could resolve.

### Verdict: NPC-target dragging is fully native-only, zero new asset — same conclusion as `PHASE3_SPEC.md`, confirmed

Player-target dragging remains native-only from a pure-scripting standpoint
(same natives as the NPC case, called from the dragged player's own client
per §12.0 item 1's architecture) but is blocked on the external "is this
player downed" integration point, which no native search can resolve —
confirmed as a real, not merely assumed, gap.

---

## 5. Advanced Agility — fence/window vault (`Config.Features.AgilityAdvanced`, `PHASE3_SPEC.md` §12.5.5)

### Confirmed natives

| Native | Hash | Namespace | Signature |
|---|---|---|---|
| `START_SHAPE_TEST_CAPSULE` | `0x28579D1B8F8AAC80` | SHAPETEST | `int START_SHAPE_TEST_CAPSULE(float x1, float y1, float z1, float x2, float y2, float z2, float radius, int flags, Entity entity, int p9)` — doc text: "Raycast from point to point, where the ray has a radius." Confirmed real; this is the correct native for §12.5.5's detection-method (a) (raycast/shape-test height detection). |
| `GET_SHAPE_TEST_RESULT` | `0x3D87450E15D98694` / alt `0xF3C2875A` | SHAPETEST | `int GET_SHAPE_TEST_RESULT(int shapeTestHandle, BOOL* hit, Vector3* endCoords, Vector3* surfaceNormal, Entity* entityHit)` — doc text: for async shape tests, call repeatedly "until returning 0 or 2, after which the handle is invalidated" (0 = invalid handle, 1 = still processing, 2 = complete with valid data). This return-code polling contract is a concrete implementation detail §12.5.5's sketch doesn't currently spell out — worth flagging for whoever implements this so it isn't assumed to be a single synchronous call. |
| `SET_ENTITY_VELOCITY` | `0x1C99BB7B6E96D16F` / alt `0xFF5A1988` | ENTITY | `void SET_ENTITY_VELOCITY(Entity entity, float x, float y, float z)` — confirmed real; the natural primitive for §12.5.5's "short forced-arc reposition... over the obstacle" description (an upward+forward velocity impulse), an alternative/complement to a hard `SetEntityCoords` teleport. |
| `TASK_PLAY_ANIM` | (as in §1 table above) | TASK | For whatever jump/vault pose is layered over the arc — see the animation caveat below. |

### On a dedicated ped "jump" task — CONFIRMED: no such native exists (absence confirmed, not just unfound)

Searched specifically for a generic `TASK_JUMP`-shaped native in the
canonical `citizenfx/natives` TASK namespace: **no such native exists.**
This is consistent with (and now confirms) `client/movement.lua`'s own
existing framing that jump is "inherent to the ped model," driven by the
native locomotion/control-input system (`INPUT_JUMP`, control index 22,
already used by this codebase's own `AgilityBasicJump` suppression thread),
not a scriptable task. This means §12.5.5's "native jump task" phrasing is
slightly imprecise — there is no discrete jump *task* to invoke
programmatically the way `TaskCombatPed` or `TaskPlayAnim` are tasks;
the actual implementation path is either (a) let the ped model's own native
locomotion jump fire from player input as normal and layer the scripted
arc/`SetEntityVelocity` boost on top when a vaultable obstacle is detected
near a jump input, or (b) skip relying on the native jump input entirely and
drive the whole arc via `SetEntityVelocity`/`SetEntityCoords` directly,
triggered by the radial/keypress §12.5.5 already describes. Either is
native-only and buildable; this is a precision correction to §12.5.5's
wording, not a feasibility problem.

### Vault/quadruped animation — CONFIRMED: not verified this session, same as `PHASE3_SPEC.md`'s own flag, and this pass adds nothing new

§12.5.5's own open-questions list already states "exact vault natives/
animation for a quadruped skeleton — not verified this session." No
searching this session surfaced a quadruped-specific vault/climb clip
distinct from the Bite-and-Hold `takedown_from_back` clip found in §1 above
(which is a melee pose, not a vaulting/climbing pose, and not a fit here).
**This remains genuinely unresolved** — unlike Bite-and-Hold where a
plausible (if imperfect) candidate clip was found, no equivalent candidate
was found for vaulting. `SPEC.md` §7's own conclusion ("a real climbing
animation blended to arbitrary fence heights would need a custom clip set;
not attempted here") is not contradicted by anything found this session —
if anything it's reinforced by the complete absence of any hit.

### Verdict: native-only-approximation for the MECHANICAL vault (shape-test + velocity-arc), CONFIRMED needs-real-custom-asset for a genuine climbing animation — unchanged from `SPEC.md` §7, now with concrete natives named for the mechanical half

The obstacle-detection natives (`StartShapeTestCapsule`/`GetShapeTestResult`)
are real, confirmed, and sufficient for detection-method (a). The
reposition primitive (`SetEntityVelocity`, alternatively `SetEntityCoords`)
is real and confirmed. No jump *task* native exists (a wording correction,
not a blocker). No quadruped vault/climb animation was found or is expected
to exist as a reusable vanilla asset — this stays a scripted-arc
approximation with no genuine climbing motion, exactly as `SPEC.md` §7
already concluded, and `PHASE3_SPEC.md` §12.5.5's detection-method fork
(raycast vs. tagged-prop) remains a real, unresolved design question this
note does not attempt to settle (per this task's explicit scope).

---

## Summary — status of `PHASE3_SPEC.md`'s own flagged "not verified this session" items

| Item | `PHASE3_SPEC.md` location | Resolution this session |
|---|---|---|
| Bite/attack anim + dict/clip name | §12.5.1 | **Partially resolved.** A real candidate found (`creatures@rottweiler@melee@streamed_core@` / `takedown_from_back`), Rottweiler-only, one-shot pose not a sustained hold loop, MEDIUM confidence (one-notch-removed source, `forge.plebmasters.de` itself blocked). Needs in-engine preview before treating as final. |
| Fall-damage-suppression native/flag | §12.5.2 | **Resolved.** No dedicated fall-damage flag confirmed to exist; `SetEntityCanBeDamaged(entity, false/true)` bracketing the forced ragdoll is the real, confirmed, native-only mechanism — broader than fall-damage-specific but directly satisfies the "no lethal damage from the hold" requirement. `SetEntityInvincible` explicitly NOT recommended (documented ragdoll-suppression side effect on at least one damage source). |
| `TaskRagdollPed`'s real native name | §12.5.2 (informal name used in prose) | **Resolved.** No such page/native exists under that name in the canonical natives repo; the real native is `SET_PED_TO_RAGDOLL` (or `SET_PED_TO_RAGDOLL_WITH_FALL` for a directional knockdown, recommended as the better fit). |
| Vault natives/animation for a quadruped skeleton | §12.5.5 | **Mechanical half resolved** (`StartShapeTestCapsule`/`GetShapeTestResult`/`SetEntityVelocity`, all confirmed real). **Animation half stays unresolved** — no candidate clip found this session, same conclusion as `SPEC.md` §7. |
| "Native jump task" wording | §12.5.5 | **Corrected.** No generic ped jump task native exists at all — jump is native-locomotion/input-driven, not task-driven; a wording precision fix, not a feasibility change. |

No item in this table was left completely untouched — every one has either
a concrete resolution, a narrowed-but-still-open status with a named next
verification step (in-engine anim preview), or a confirmed absence (jump
task, downed-state native) that turns a "someone should check" into a
"confirmed not to exist, stop looking for it."

---

## Sources

- [SetPedToRagdoll.md](https://github.com/citizenfx/natives/blob/master/PED/SetPedToRagdoll.md)
- [SetPedToRagdollWithFall.md](https://github.com/citizenfx/natives/blob/master/PED/SetPedToRagdollWithFall.md)
- [CanPedRagdoll.md](https://github.com/citizenfx/natives/blob/master/PED/CanPedRagdoll.md)
- [IsPedRagdoll.md](https://github.com/citizenfx/natives/blob/master/PED/IsPedRagdoll.md)
- [IsPedDeadOrDying.md](https://github.com/citizenfx/natives/blob/master/PED/IsPedDeadOrDying.md)
- [SetBlockingOfNonTemporaryEvents.md](https://github.com/citizenfx/natives/blob/master/PED/SetBlockingOfNonTemporaryEvents.md)
- [SetPedFleeAttributes.md](https://github.com/citizenfx/natives/blob/master/PED/SetPedFleeAttributes.md)
- [SetPedMoveRateOverride.md](https://github.com/citizenfx/natives/blob/master/PED/SetPedMoveRateOverride.md)
- [AttachEntityToEntity.md](https://github.com/citizenfx/natives/blob/master/ENTITY/AttachEntityToEntity.md)
- [DetachEntity.md](https://github.com/citizenfx/natives/blob/master/ENTITY/DetachEntity.md)
- [SetEntityCanBeDamaged.md](https://github.com/citizenfx/natives/blob/master/ENTITY/SetEntityCanBeDamaged.md)
- [SetEntityInvincible.md](https://github.com/citizenfx/natives/blob/master/ENTITY/SetEntityInvincible.md)
- [SetEntityVelocity.md](https://github.com/citizenfx/natives/blob/master/ENTITY/SetEntityVelocity.md)
- [NetworkRequestControlOfEntity.md](https://github.com/citizenfx/natives/blob/master/NETWORK/NetworkRequestControlOfEntity.md)
- [NetworkGetEntityFromNetworkId.md](https://github.com/citizenfx/natives/blob/master/NETWORK/NetworkGetEntityFromNetworkId.md)
- [TaskPlayAnim.md](https://github.com/citizenfx/natives/blob/master/TASK/TaskPlayAnim.md)
- [TaskCombatPed.md](https://github.com/citizenfx/natives/blob/master/TASK/TaskCombatPed.md)
- [StartShapeTestCapsule.md](https://github.com/citizenfx/natives/blob/master/SHAPETEST/StartShapeTestCapsule.md)
- [GetShapeTestResult.md](https://github.com/citizenfx/natives/blob/master/SHAPETEST/GetShapeTestResult.md)
- `docs.fivem.net/natives/?_0x57FFF03E423A4C0B=` (TASK_COMBAT_PED, cross-referenced via search-index snippet since direct fetch is blocked)
- Pleb Masters: Forge animation data-browser search-index results for
  `creatures@rottweiler@melee@streamed_core@` / `takedown_from_back_facial`
  (site itself blocked for direct fetch this session — see confidence
  caveat in §1 above; page existence/URL/date metadata corroborated via
  multiple independent `WebSearch` queries returning the same dict/clip
  pair and an October 2014/"Patchday 2ng" release attribution)
- GTAForums "Ped Config Flags" community thread (used only to confirm the
  *absence* of a clean, documented fall-damage-suppression flag — its
  flag-number observations were not treated as a usable API, see §2 above)
- This codebase's own `client/vehicle.lua` (`AttachEntityToEntity`/
  `DetachEntity` real in-repo usage precedent) and `client/movement.lua`
  (`DisableControlAction`/`INPUT_JUMP` established precedent, and the
  `K9_SIT_SCENARIO_BY_MODEL_HASH` per-breed mapping precedent this note's
  Bite-and-Hold section explicitly mirrors)

Note: as with every prior `phase2_notes/*_natives.md` file in this
codebase, `docs.fivem.net` itself could not be reached directly this
session (`EGRESS_BLOCKED`, re-confirmed at the start of this pass) — all
native hash/signature claims above trace to `raw.githubusercontent.com/
citizenfx/natives`, the same upstream source `docs.fivem.net` is generated
from, not to memory. Anim-dictionary/clip claims (which have no natives-repo
equivalent, since animations are game data, not natives) are explicitly
flagged with their own, lower confidence level per-item above rather than
being presented with native-doc-level certainty.
