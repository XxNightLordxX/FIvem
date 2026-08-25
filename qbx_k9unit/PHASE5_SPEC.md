# qbx_k9unit — Phase 5 Detailed Spec (continued): ProximityAudioFX,
# PropAttachments, FetchMechanic

> **HISTORICAL DESIGN DOCUMENT.** This captures the plan and reasoning as of
> the date named inside it (2026-08-24), not a live description of today's
> code. `config.lua` and the actual `.lua` files always win if something
> here disagrees with them. See `DOCS_INDEX.md` for where to look for
> current status instead (`README.md` for technical reference,
> `PROJECT_STATUS.md` for a plain-language snapshot and open decisions).
> Kept in full, unmerged with the other phase specs, because each covers a
> distinct, non-overlapping phase — added by a documentation-consolidation
> pass, 2026-08-25; nothing below this banner was edited.

Status: **planning only — no `.lua`/`config.lua`/`fxmanifest.lua` file was
touched to produce this document.** `DeployableKennel` and
`AdvancedBarkRadial` (the other two `SPEC.md` §6.7 line items) are already
implemented (`client/kennel.lua`/`server/kennel.lua`,
`client/radial.lua`'s Bark submenu + `config.lua`'s `Config.AdvancedBarkRadial`,
confirmed by direct read this pass) and are **not** respecified here.
`CameraFeedPiP` was independently researched and concluded impossible for a
true inset feed (`phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` §6, corroborated
by a live upstream `citizenfx/fivem` issue) — also **not** covered here.
This document's entire scope is the three Phase 5 items that were researched
but never specced: `ProximityAudioFX`, `PropAttachments`, `FetchMechanic`.

Author: product-agent, 2026-08-24, jlwood17190665@gmail.com.

## Source material (read in full to produce this document, not re-derived)

- `phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` — the decisive pass.
  Its findings are treated as settled fact throughout this document, not
  re-litigated: ProximityAudioFX's mechanism (an NUI `GainNode`, or — this
  document's own conclusion below — a native discrete-clip-tier approach) is
  buildable, but the feature has **no live "hidden suspect" detection
  primitive** to drive it; `PropAttachments`/`FetchMechanic` need a bone
  **index**, not a **name**, which reframes an indefinitely-blocked research
  question into a bounded, one-time in-engine sweep; `FetchMechanic`'s
  pursue/carry logic is simpler than its one real precedent once re-scoped
  around a real player's own movement, and its mouth-carry is the *same*
  open bone item as `PropAttachments`' vest, not a separate one.
- `phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` and
  `phase2_notes/RESEARCH_ARCHIVE.md#dependencies-and-audio` — the audio-asset baseline:
  every bark in this resource today (`client/main.lua`'s `BARK_SOUND_NAME`/
  `K9_SOUND_SET`, `config.lua`'s `Config.AdvancedBarkRadial`) is a
  placeholder soundset name that resolves to a harmless `PlaySoundFromEntity`
  no-op. There is no real audio anywhere in this resource. A real custom
  soundset needs authored `.awc`/`dat151`/`dat54` RAGE-audio-bank assets (the
  native path) or licensed `.ogg` files delivered through an NUI bridge (the
  cheaper path `RESEARCH_ARCHIVE.md#dependencies-and-audio` recommends, and which a
  coder-ui pass is reportedly building the plumbing for right now,
  independently of this document — see fork 1 below for how this spec
  avoids depending on that in-flight code's specifics).
- This resource's own shipped code, read directly this pass:
  `config.lua` (`Config.Features`, `Config.Peds`, `Config.AdvancedBarkRadial`,
  `Config.DeployableKennel`), `client/main.lua` (`CanShowK9UI`/`HasK9Access`/
  `IsOwnModelK9`'s "only call the combinator" contract, `BarkTypeSoundNames`,
  `PlaySoundOnNetworkEntity`, `ResolveNetworkEntity`), `client/radial.lua`
  (the Bark submenu's config-driven-list-to-radial-items pattern, and every
  toggle-shaped item's "release is not gated on `CanShowK9UI()`" convention),
  `client/vehicle.lua` (`AttachEntityToEntity` in real, working, **purely
  client-side, no server round trip** use for the K9's own ped —
  the load-bearing precedent for §14.4.2's trust-model decision),
  `client/kennel.lua`/`server/kennel.lua` (the full spawn/confirm/cleanup
  lifecycle pattern reused for `FetchMechanic`'s ball), `server/tracking.lua`
  (`findTrackableSource`, confirmed by direct read to resolve a **historical
  logged coordinate**, not a live entity — the concrete evidence behind
  fork 2 below), `server/main.lua` (`relayBark`'s cooldown/length-cap/
  broadcast pattern, and `relayDoorScratch`'s deliberately **independent**
  cooldown table — the precedent fork 2 below follows for `ProximityAudioFX`),
  `client/combat.lua`/`phase2_notes/RESEARCH_ARCHIVE.md#phase-3-combat`
  (`NETWORK_REQUEST_CONTROL_OF_ENTITY` and the "re-assert every tick" vs.
  "one-shot is fine" distinction — reused for `FetchMechanic`'s ball attach),
  `client/hud.lua`/`html/app.js` (the only NUI bridge that exists today — a
  **vitals-only**, non-audio bridge; confirmed by direct read that no
  `<audio>`/Web-Audio code exists anywhere in this resource yet), and
  `fxmanifest.lua` (current file lists, dependency versions).

**Confidence convention carried over unchanged** from every `phase2_notes/*`
file this pass is built on: a claim needs two independent sources to be
CONFIRMED; a single-source lead is PLAUSIBLE/UNCONFIRMED and flagged as such
inline, never silently upgraded.

## Relationship to `SPEC.md` and this project's document-scale precedent

Same convention `PHASE3_SPEC.md`/`PHASE4_SPEC.md` already established: this
document is written to eventually become `SPEC.md`'s next section (`§14`,
continuing `§12`/`§13`'s numbering) once someone with safe incremental-edit
access folds it in. It is not folded in now for the same reason those two
documents weren't — this agent's toolset has no line-level edit capability,
and `SPEC.md` is large enough that a whole-file rewrite to append one section
is an avoidable risk. Until folded in, treat this as authoritative detail
that supplements, and where more specific supersedes, `SPEC.md` §6.7's three
remaining bullets and §7's "scope reality check" row for prop attachments —
reconcile against `SPEC.md` directly if the two ever drift.

Every feature specified below ships behind its own already-declared
`Config.Features` flag (`ProximityAudioFX`, `PropAttachments`,
`FetchMechanic`, all `false` in `config.lua` today) and **stays `false`**
after this spec is implemented, matching this resource's own established
"a newly-landed mechanic stays off by default until its own review" posture
(`config.lua`'s own comment on `HandlerPartnership`'s default makes this
explicit for Phase 3; the same posture applies here with no exception
argued for).

---

## 14.0 — Cross-cutting design forks: resolved before any per-feature spec assumes an answer

### Fork 1 — the bone-index dependency (blocks `PropAttachments` and half of `FetchMechanic`)

**Resolution: this is a bounded, one-time engineering task, not a further
research question, and its output is a config table — not a design
decision left open.**

`phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` confirms
`AttachEntityToEntity`'s bone-index parameter accepts a raw integer either
way — a documented bone **name** (`GetEntityBoneIndexByName`) was never
actually load-bearing for the mechanical attach, only for the convenience of
looking one up by string. `GetWorldPositionOfEntityBone(entity, boneIndex)`
is entity-type-agnostic (confirmed directly against `citizenfx/natives`) and
works on any raw integer index regardless of whether a name for it is
documented anywhere. This converts "find a documented animal-skeleton bone
name" (a research task every accessible source has now failed at across two
full sessions) into "find a usable numeric index by direct in-engine
observation" (an engineering task, completable in one dev-server sitting).

**The concrete procedure, precise enough for a coder to execute without
guessing:**

1. Write a **throwaway, dev-only** script (e.g. `dev/bone_sweep.lua`) — this
   is *not* added to `fxmanifest.lua`'s permanent file lists, and is deleted
   or manually excluded once the sweep session is done. It is not part of
   this feature's shipped code.
2. On a dev server, spawn (or possess/ride) a K9 ped of one
   `Config.Peds` model at a time (all four: `a_c_shepherd`,
   `a_c_rottweiler`, `a_c_husky`, `a_c_chop` — the research explicitly
   flags that skeleton consistency across breeds is **not** confirmed
   either way, so all four must be swept independently, not assumed
   identical).
3. Loop `boneIndex = 0` to `199` (a ceiling of 200, per the research's own
   flagged, unconfirmed-but-defensive guess for `a_c_*` bone count — an
   out-of-range index is expected, per `GetEntityBoneIndexByName`'s sibling
   convention, to fail gracefully rather than crash, but this has **not**
   been independently re-confirmed for `GetWorldPositionOfEntityBone`
   specifically this session — if a given index errors instead of returning
   a degenerate value, wrap the per-index call in `pcall` defensively rather
   than assuming it can't).
4. For each index, call `GetWorldPositionOfEntityBone(ped, boneIndex)` and
   draw an in-world marker (`DrawMarker`) plus a 3D label showing the raw
   index number at the returned position — either all at once, or
   step-through via a keybind, developer's choice. There is **no confirmed
   sentinel value** distinguishing a "real" bone from an "invalid index"
   result for this specific native this session (unlike
   `GetEntityBoneIndexByName`'s documented `-1`-on-miss) — do not attempt to
   auto-filter; visually inspect all 200 per model.
5. A developer visually identifies, per model: (a) an index that sits near
   the neck/shoulder/back region (the vest/harness anchor `PropAttachments`
   needs) and (b) an index that sits near the mouth/jaw region (the carry
   anchor `FetchMechanic` needs). **While doing (b), also trigger this
   resource's existing `WORLD_DOG_BARKING_SHEPHERD`/`_ROTTWEILER`/
   `_RETRIEVER` scenario (already in real use, `client/movement.lua`) with a
   test prop attached at the candidate mouth index and watch for visible
   clipping** — this is the one extra check `FetchMechanic`'s mouth-carry
   needs that `PropAttachments`' vest doesn't (a rigid back-mounted vest
   does not need to track fine jaw articulation the way a mouth-held prop
   does).
6. Record the results directly into `config.lua`'s new `Config.K9BoneIndices`
   table (schema in §14.2) — one row per `Config.Peds` model, two integer
   fields (`vestBoneIndex`, `mouthBoneIndex`), plus one new field decided by
   step 5's clipping check (`mouthCarryMode`, see `Config.FetchMechanic`'s
   `mouthCarryModeByModel` in §14.2). If no bone distinctly separate from
   the root/spine is found for a given model, record `nil` for that field
   rather than a guess — see §14.4.2/§14.4.3 for what each feature does with
   an unresolved value (a documented, disclosed fallback, never a silent
   guess or a crash).

**Scope note:** this sweep is a **single dev-server task that unlocks both
features at once** (per the research's own explicit recommendation) — it is
not scheduled twice, and neither feature's flag should flip to `true` on a
live server until at least the models that server actually issues (per its
own `Config.Peds` list) have been swept at least once.

### Fork 2 — `ProximityAudioFX`'s missing "hidden suspect" detection primitive

**Resolution: DO NOT build a new live-entity "is this ped currently hidden"
detection primitive in this pass. Ship the feature's real, buildable half
(the audio-delivery mechanism) fully working, with the trigger condition
exposed as an explicit, disclosed, `nil`-by-default integration hook — the
same "we cannot resolve this ourselves, here is the seam" pattern this
codebase already uses twice in Phase 3 for an analogous problem.**

The research is decisive and re-confirmed directly this pass
(`server/tracking.lua`'s `findTrackableSource`, read in full): this
resource's one existing "find something interesting near the K9" mechanism
resolves the nearest still-fresh **logged coordinate** — a historical event
location — not a live entity's current position, and is pull-based
(one-shot "Track" request), not a continuously-updating push signal. A
repo-wide check for any "is this ped currently hidden/crouching/stealthed"
concept anywhere in this codebase found nothing. Building a real one (who
flags a ped "hidden" — a crouch check? a foliage-proximity check? a manual
player action? server-authoritative or heuristic?) is genuine, undersized-
by-`SPEC.md`'s-one-line-wording design and implementation work, not a
natives-availability gap this document can resolve by more research, and not
something this pass invents unilaterally on a codebase-wide-impact decision
of this size.

**A considered, explicitly-rejected alternative, named here for honesty
rather than silently discarded:** reusing `findTrackableSource`'s resolved
coordinate (from an active `ScentTracking`/`BloodTracking`/`GunpowderSniffing`
trail) as a stand-in "suspect" distance target was considered. **Rejected**
as the default, for two reasons: (1) it is a static historical point, not a
live, potentially-fleeing suspect — using it here would silently repurpose
Phase 4's `trackSourceResolved` XP-arrival primitive for an unrelated
gameplay signal without any dedicated design pass agreeing that's a sound
reuse; (2) it would only ever apply while a Phase 2 tracking flag is also on
and a trail is active, which is a materially narrower and differently-shaped
trigger condition than `SPEC.md` §6.7's "a suspect entity flagged as
'hidden'... within a configured radius" wording describes, and dressing that
narrower thing up as satisfying the original ask would be exactly the kind
of undisclosed scope-narrowing this project's own conventions reject
elsewhere (see `PHASE3_SPEC.md` §12.0 item 7's rejection of `LeashPairs`
reuse for the identical class of reason: "presenting a check that looks like
it does the job while not doing it for the case that matters most"). A
future dedicated pass remains free to wire this reuse in explicitly via the
hook below if that's judged acceptable later — it is not decided here.

**Concrete resolution, mirroring `PHASE3_SPEC.md` §12.0 items 5/6's
"default-check-plus-override-hook" shape exactly** (`Config.Combat.
RequireWantedStatus`/`WantedStatusCheckOverride`,
`Config.Combat.PropDragging.IsPlayerDownedOverride`) and `SPEC.md` §2's own
"exports/events will be exposed so such integration is possible, but no
particular external resource is assumed to exist" non-goal posture:

- `Config.ProximityAudioFX.SuspectDistanceSource` — `function() -> number?`,
  `nil` by default. Evaluated on the K9 player's own client, on a tick
  (`Config.ProximityAudioFX.tickMs`). Must return the current live distance
  in meters from the K9's own ped to whatever *this server's own*
  hidden-suspect concept currently considers relevant, or `nil` if none
  applies right now. **This resource does not and — per the finding above —
  cannot supply a sensible default implementation for this on its own.**
  Unlike `WantedStatusCheckOverride`/`IsPlayerDownedOverride` (which at
  least have a plausible `metadata.*` guess to fall back on), there is no
  ecosystem-dominant metadata convention for "is this ped hidden" to guess
  at — so this hook ships with **no default implementation at all**, only
  the seam.
- While `SuspectDistanceSource` stays `nil` (the shipped state), the feature
  is **real, wired, and inert**: the tick loop runs, evaluates the hook,
  gets `nil`, and never fires a growl. This is the identical "plumbing
  real, payload absent, safe no-op" posture `BARK_SOUND_SET`'s own
  placeholder convention already established for Phase 1's bark and Phase
  5's `AdvancedBarkRadial` — not a new philosophy, an extension of an
  existing one.
- Flipping `Config.Features.ProximityAudioFX` to `true` on a live server
  without ever wiring `SuspectDistanceSource` is **not a bug** and does not
  need to be prevented defensively — it degrades to "the feature does
  nothing observable," the same safe-inert state every other placeholder
  gap in this resource already ships in.

**What this means for acceptance criteria (§14.4.1):** they cover the
audio-delivery mechanism (tick loop, distance-to-tier mapping, relay event,
playback) as a fully real, checkable, buildable thing — and explicitly do
**not** include "a hidden suspect is correctly detected," because this
document does not build that detector. This is the "well-argued not yet,
and here's the precondition" outcome this task explicitly permits, applied
to exactly the half of the feature the research found has no existing
scaffolding to build on.

### Fork 3 — asset dependency: what ships working with zero assets vs. what needs an operator to supply something

Stated plainly, per feature, so nothing below is specced as "done" when a
real visual/audio payload is actually still missing:

| Feature | Ships fully functional with **zero** new assets? | What an operator must supply for the full experience |
|---|---|---|
| `ProximityAudioFX` | **Audio delivery mechanism: yes** (reuses the exact placeholder-soundset-name convention `BasicBarkSounds`/`AdvancedBarkRadial` already ship safely with — a harmless `PlaySoundFromEntity` no-op). **The trigger condition: no** — see fork 2; it will never fire at all until an operator wires `SuspectDistanceSource`, independent of whether real audio exists. | Real, distinct growl/pant audio (the SAME asset-sourcing task already named, not duplicated, for `AdvancedBarkRadial` — see `phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` §1), **and** a `SuspectDistanceSource` implementation (a new, separate, non-audio integration task — see fork 2). |
| `PropAttachments` | **No.** Unlike `DeployableKennel` (which found at least one plausible, if unconfirmed, vanilla prop name to fall back on, `prop_doghouse_01`), **no research pass across this project found any generically-real "close enough" placeholder prop for a quadruped vest/harness** — `SPEC.md` §7's own table already concluded a purpose-built model is most likely needed. Per this project's own established discipline (`config.lua`'s `Config.DeployableKennel` comment explicitly declines a *second* unverified prop-name guess for exactly this reason), this document does **not** invent one either. | A real prop model name (custom-modeled, or a confirmed-suitable vanilla GTA prop if one is later identified) — `propModel` ships `nil`, and the feature safely no-ops (logs once, does nothing visible) until an operator sets it. |
| `FetchMechanic` | **Yes, for the ball itself** — `prop_tennis_ball` is the single highest-confidence prop name found across every Phase 5 research pass (traced to a real, source-read, shipped community script's own config default, not a guess). Spawn/throw/lifecycle are fully native-only. **The mouth-*carry* fidelity is conditional** on fork 1's sweep outcome — see §14.4.3's `mouthCarryModeByModel`, which defaults every model to the zero-asset `'fake'` (delete-and-animate) mode until a developer's sweep session explicitly upgrades a specific model to `'attach'`. | Nothing required for a working feature. Optionally: a custom "evidence bag" prop as a reskin of the ball concept (named in `SPEC.md` §6.7, not required for v1), and whatever real carry animation/scenario `'fake'` mode uses if the existing bark/pant scenarios aren't judged good enough as a stand-in (open question, §14.4.3). |

### Fork 4 (smaller, but load-bearing for §14.2/§14.3) — where does `ProximityAudioFX`'s automatic growl-relay cooldown live?

**Resolution: a brand-new event and cooldown table, not a reuse of
`relayBark`'s.** `server/main.lua`'s own existing precedent already
establishes this exact discipline for a structurally identical situation —
`relayDoorScratch` deliberately does **not** share `BarkCooldown`, per that
file's own comment: "Bark and door-scratch are two independently cooldowned
actions... a player who just barked should not have that consumed against
their separate door-scratch allowance." `ProximityAudioFX`'s growl fires
**automatically and repeatedly** (once every `distanceTiers[n].cadenceMs`
while a suspect signal is active, potentially every ~800ms at the closest
tier) — reusing `BarkCooldown`'s existing 1000ms-per-source floor
(`BARK_COOLDOWN_MS`, `server/main.lua`) would silently starve a player's
ability to manually Bark while a growl loop is active, or vice versa,
purely as an artifact of sharing one budget between two semantically
unrelated actions. §14.2/§14.3 below give this its own event
(`qbx_k9unit:server:relayGrowl`), own cooldown table, and own length cap —
small, but a real, disclosed decision, not an oversight.

---

## 14.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| **5a — independent, start immediately** | Fork 1's bone-index sweep (`dev/bone_sweep.lua`, throwaway) | Blocks 5c and half of 5d. Cheap (one dev-server sitting), bounded (200-index ceiling × 4 models), and unlocks two features at once per its own recommendation — do not schedule it twice. |
| **5b — independent, start immediately, in parallel with 5a** | `ProximityAudioFX` | Entirely unrelated to bone attachment — no dependency on 5a at all. Ships functionally inert (fork 2) until an operator wires `SuspectDistanceSource`; that wiring is explicitly **not** part of this sub-phase's own completion criteria. |
| **5c — depends on 5a** | `PropAttachments` | The mechanical attach itself (`AttachEntityToEntity`) needs zero new research (already proven in this codebase, `client/vehicle.lua`) — this sub-phase is blocked only on 5a's recorded `vestBoneIndex` values existing for whichever `Config.Peds` models the target server actually issues. A `nil` value degrades to the documented fallback-offset path (§14.4.2), so this sub-phase is not *fully* blocked, only quality-blocked, on 5a. |
| **5d — spawn/throw/lifecycle independent of 5a; mouth-carry depends on 5a** | `FetchMechanic` | The ball's spawn/throw/pickup/drop/cleanup lifecycle (native-only, reuses `client/kennel.lua`/`server/kennel.lua`'s own shipped pattern) can start immediately, with `mouthCarryModeByModel` defaulted to `'fake'` for every model. Upgrading any model to `'attach'` mode is gated on that model's 5a sweep result **and** its clipping check passing — a real but narrow, per-model, non-blocking-to-ship-the-rest-of-the-feature dependency. |

---

## 14.2 Config schema additions (sketch)

**Every numeric value below is an unreviewed placeholder**, same status
every prior phase's own config sketch carries — flagged for a
config-validator pass before any of these flags default to `true` on a live
server (none of them do; all three stay `false`, per this document's own
opening note).

```lua
-- ======================================================================
-- SHARED BY PropAttachments AND FetchMechanic (PHASE5_SPEC.md fork 1).
-- Populated ONLY by running dev/bone_sweep.lua (throwaway, NOT part of
-- this resource's shipped file list) against a live instance of each
-- Config.Peds model and recording the result by hand. Every field below
-- defaults to nil ("unresolved, sweep not yet run for this model") --
-- PropAttachments/FetchMechanic each have their own documented, disclosed
-- fallback for a nil value (see their own sections below), never a guess
-- or a crash.
-- ======================================================================
Config.K9BoneIndices = {
    a_c_shepherd   = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_rottweiler = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_husky      = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_chop       = { vestBoneIndex = nil, mouthBoneIndex = nil },
}

-- Fallback offset from bone index 0 (the root bone), used ONLY when a
-- given model's Config.K9BoneIndices entry above is still nil at runtime.
-- UNTUNED placeholders -- a reasonable-looking guess, not a playtested
-- value, same status every other "reasonable-looking, not playtested"
-- constant in this resource's config carries (e.g. PHASE3_SPEC.md's vault
-- constants). Mirrors client/vehicle.lua's own root-bone-plus-offset
-- precedent for its ped-in-vehicle attach, extended here to props.
Config.K9BoneFallbackOffsets = {
    vest  = { x = 0.0, y = 0.15, z = 0.35 },
    mouth = { x = 0.0, y = 0.45, z = 0.15 },
}

-- ======================================================================
-- PHASE 5 -- PROXIMITY AUDIO FX (Config.Features.ProximityAudioFX, still
-- `false`). Layered on top of Config.Features.BasicBarkSounds, same
-- convention Config.AdvancedBarkRadial already established. See
-- PHASE5_SPEC.md §14.0 fork 2 for why SuspectDistanceSource ships nil with
-- no default implementation, and fork 4 for why this has its OWN cooldown
-- rather than sharing server/main.lua's BarkCooldown.
-- ======================================================================
Config.ProximityAudioFX = {
    tickMs = 1000, -- client-side evaluation cadence (client/proximityaudio.lua)

    -- function() -> number?, OPTIONAL, nil by default. See §14.0 fork 2 in
    -- full before wiring this -- this resource cannot supply a sensible
    -- default on its own (no ecosystem-dominant "is this ped hidden"
    -- metadata convention exists to guess at, unlike Config.Combat's
    -- WantedStatusCheckOverride/IsPlayerDownedOverride). While nil, this
    -- feature is real, wired, and inert -- not a bug, the documented
    -- shipped state.
    SuspectDistanceSource = nil,

    -- Ordered nearest-to-farthest. growlType is an opaque string, same
    -- placeholder-audio posture as Config.AdvancedBarkRadial's `sound`
    -- field -- none of these resolve to real, distinct authored audio yet.
    -- Kept at or under GROWL_TYPE_MAX_LENGTH (server/main.lua, mirrors
    -- BARK_TYPE_MAX_LENGTH's own bandwidth-bound reasoning).
    distanceTiers = {
        { maxDistanceMeters = 5.0,  growlType = 'growl_close', cadenceMs = 800 },
        { maxDistanceMeters = 12.0, growlType = 'growl_near',  cadenceMs = 1500 },
        { maxDistanceMeters = 25.0, growlType = 'growl_far',   cadenceMs = 2500 },
        -- Beyond the last tier's maxDistanceMeters, or SuspectDistanceSource
        -- returning nil: no growl fires at all.
    },

    -- Defensive per-source floor on the NEW relayGrowl event (server/main.lua),
    -- independent of BarkCooldown -- see §14.0 fork 4. Must stay comfortably
    -- BELOW the fastest configured tier's cadenceMs above, or the closest
    -- tier would be silently throttled below its own intended cadence.
    serverCooldownMs = 500,
}

-- ======================================================================
-- PHASE 5 -- PROP ATTACHMENTS (Config.Features.PropAttachments, still
-- `false`). SPEC.md §6.7: "vest, harness, tracking camera... via
-- AttachEntityToEntity." See PHASE5_SPEC.md §14.0 fork 3 -- propModel ships
-- nil for every slot below; no generically-real placeholder was found or
-- guessed (unlike DeployableKennel's fallbackPropModel) -- do not add one
-- here without a real, independently-confirmed lead.
-- ======================================================================
Config.PropAttachments = {
    {
        id        = 'vest',
        label     = 'Equip/Unequip Vest',
        icon      = 'vest',
        propModel = nil, -- OPERATOR-SUPPLIED. Feature safely no-ops (logs once) while nil -- see §14.4.2.
        boneField = 'vestBoneIndex', -- key into Config.K9BoneIndices[currentModel]
    },
    -- Additional slots (harness, tracking-camera housing) follow the exact
    -- same shape -- add entries here, do not add new Lua branches per slot.
    -- A "tracking camera" slot is COSMETIC ONLY in this spec -- explicitly
    -- no functional link to CameraFeedPiP (out of this document's scope,
    -- independently concluded impossible for a true feed -- see this
    -- file's own header).
}

-- ======================================================================
-- PHASE 5 -- FETCH MECHANIC (Config.Features.FetchMechanic, still `false`).
-- See PHASE5_SPEC.md §14.4.3 for the full event contract, modeled directly
-- on client/kennel.lua/server/kennel.lua's own shipped lifecycle pattern.
-- ======================================================================
Config.FetchMechanic = {
    -- CONFIRMED real & free (RESEARCH_ARCHIVE.md#phase-5-research §3 /
    -- RESEARCH_ARCHIVE.md#phase-5-research §4 -- highest-confidence prop name found
    -- across every Phase 5 research pass, traced to a real, source-read
    -- community script's own shipped config default, not a guess).
    ballPropModel = 'prop_tennis_ball',

    -- Spawn offset + throw impulse, computed server-side from the
    -- THROWER's own live position/forward vector -- mirrors
    -- server/kennel.lua's "why the server computes the placement coords"
    -- rationale. UNTUNED placeholders; throwForceForward/throwForceUp match
    -- the shape (not necessarily the exact values) of the one real,
    -- source-read precedent (fruitmob/murderface-pets' ApplyForceToEntity
    -- call).
    throwForwardOffsetMeters = 1.0,
    throwUpOffsetMeters      = 1.2,
    throwForceForward        = 12.0,
    throwForceUp             = 6.0,

    throwCooldownMs     = 5000,  -- per-thrower rate limit, mirrors DeployCooldown (server/kennel.lua)
    pendingThrowTtlMs   = 15000, -- mirrors pendingPlacementTtlMs (server/kennel.lua)
    maxBallLifetimeMs   = 300000, -- safety-valve: force-despawn + free the thrower's slot if nobody ever picks up or drops it (mirrors this resource's "no unbounded state" discipline -- LEASH_REQUEST_TTL_MS, pendingPlacementTtlMs -- applied to a WORLD OBJECT'S total lifetime, not just a pending request)

    pickupInteractDistanceMeters = 2.0, -- ox_target range on the thrown ball, mirrors Config.DeployableKennel.interactDistanceMeters's order of magnitude

    -- Per-model mouth-carry behavior -- see PHASE5_SPEC.md §14.0 fork 1 /
    -- §14.4.3. 'attach' = real AttachEntityToEntity carry, only valid once
    -- Config.K9BoneIndices[model].mouthBoneIndex is resolved AND the
    -- sweep-session clipping check (bark/pant scenario) passed for that
    -- model. 'fake' = delete-and-animate fallback (the one real community
    -- precedent found, fruitmob/murderface-pets). ALL FOUR default to
    -- 'fake' until a developer's sweep session explicitly upgrades a given
    -- model -- this is the SAFE, ZERO-BONE-DEPENDENCY default, not a
    -- placeholder that blocks shipping the rest of the feature.
    mouthCarryModeByModel = {
        a_c_shepherd   = 'fake',
        a_c_rottweiler = 'fake',
        a_c_husky      = 'fake',
        a_c_chop       = 'fake',
    },
}
```

---

## 14.3 File/module plan (sketch)

| File | New/extends | Owns |
|---|---|---|
| `dev/bone_sweep.lua` | **New, throwaway** | Fork 1's raw-index visual sweep. **Not** added to `fxmanifest.lua`'s `client_scripts`/`server_scripts` lists — a one-time dev tool, deleted or excluded after use, not shipped code. |
| `client/proximityaudio.lua` | **New** | `ProximityAudioFX`'s entire client-side implementation: the tick loop (gated at file-load time on `Config.Features.ProximityAudioFX AND Config.Features.BasicBarkSounds`, mirroring `client/hud.lua`'s own "gate at registration, not just inside the loop" discipline), evaluating `Config.ProximityAudioFX.SuspectDistanceSource()`, picking a distance tier, and — respecting each tier's own `cadenceMs` — sending `qbx_k9unit:server:relayGrowl`. Also registers the receiving handler, `qbx_k9unit:client:playGrowl` (netId, growlType), which calls `client/main.lua`'s existing exported `PlaySoundOnNetworkEntity(netId, soundName)` — the exact same reuse pattern `client/movement.lua`'s `playDoorScratch` handler and `client/search.lua`'s `playContrabandAlert` handler already establish for "own file, shared helper." |
| `server/main.lua` | **Extends** | One new handler, `qbx_k9unit:server:relayGrowl` (growlType: string) — structurally a near-identical sibling of the existing `relayBark` handler immediately above it (same `Config.Features.ProximityAudioFX AND HasK9Access(src)` gate shape, same "resolve the sender's own ped/netId, never a client-supplied one" discipline, same broadcast-to-`-1`-and-let-the-audio-engine-3D-cull posture already used for `relayBark`/`relayDoorScratch`), but with its **own** cooldown table (`GrowlCooldown`, `Config.ProximityAudioFX.serverCooldownMs`) and **own** length cap (`GROWL_TYPE_MAX_LENGTH`) — see §14.0 fork 4 for why these are not shared with `BarkCooldown`/`BARK_TYPE_MAX_LENGTH`. |
| `client/main.lua` | **Extends (small)** | One new exported combinator, `CanActAsK9Handler() -> boolean`, returning `HasK9Access()` directly (no `IsOwnModelK9()` requirement) — added alongside the existing `CanShowK9UI()` per this file's own stated design principle that "the how-do-we-combine-these policy lives in exactly one place." Needed because `FetchMechanic`'s "Throw" trigger (§14.4.3) is a **human handler** action per `SPEC.md`'s own "on a handler command" wording — the thrower need not currently be riding a K9 model, unlike every other radial action this resource has shipped so far. `client/fetch.lua` calls this, not a raw `HasK9Access()` call, preserving this file's own "other files must call the combinator, never the two raw checks directly" contract rather than quietly breaking it. |
| `client/attachments.lua` | **New** | `PropAttachments`' entire implementation: builds one context-sensitive Equip/Unequip radial item per `Config.PropAttachments` slot (loop-over-config-list-building-items, exactly mirroring `client/radial.lua`'s existing `AdvancedBarkRadial` submenu-building code shape), tracks currently-attached local object handles, and handles unequip on model swap/disconnect/`onResourceStop` (mirrors `client/vehicle.lua`'s own persisted-native-state cleanup precedent). **No server file** — see §14.4.2's trust-model decision for why this, uniquely among Phase 5's new features, needs zero net events. |
| `client/radial.lua` | **Extends (small)** | Adds one new opener item to `k9SubmenuItems` (`id = 'k9_attachments'`, `menu = 'k9unit_attachments'`) plus the `lib.registerRadial({id = 'k9unit_attachments', ...})` call building that submenu's contents from `Config.PropAttachments`, and one new flat item (`id = 'k9_throw_fetch'`) for `FetchMechanic`'s "Throw Fetch Ball" — gated via the new `CanActAsK9Handler()`, **not** `CanShowK9UI()` (the one deliberate departure from this file's otherwise-universal gate, called out explicitly per its own header's "flag disagreement rather than silently building it the other way" convention). |
| `client/fetch.lua` | **New** | `FetchMechanic`'s client-side half: `RequestThrowFetchBall()` (calls `CanActAsK9Handler()`, sends the throw request, executes the server-issued `CreateObject`/`ApplyForceToEntity`/confirm sequence — same three-step shape as `client/kennel.lua`'s `RequestDeployKennel`/`deployKennelAt` pair), the "Pick Up Ball" `ox_target` entry (`addModel` by `Config.FetchMechanic.ballPropModel`'s hash, gated by `CanShowK9UI()` — the K9-player-specific gate, since only a K9 model carries anything in its mouth), the carry-attach/drop logic (branching on `Config.FetchMechanic.mouthCarryModeByModel[currentModel]`), and `onResourceStop` cleanup — mirrors `client/kennel.lua`'s own restart-safety-net precedent. |
| `server/fetch.lua` | **New** | `FetchMechanic`'s server-side half: `FetchBalls[throwerCitizenId] = { netId, state, carrierSrc }` (one active ball per thrower, mirrors `server/kennel.lua`'s `Kennels[citizenid]` one-per-handler shape and its own reasoning for choosing per-actor over per-area), `PendingFetchThrows` (mirrors `PendingKennelPlacements`), the `requestThrowFetchBall`/`confirmFetchBallThrown`/`requestPickupFetchBall`/`releaseFetchBall` handlers (re-validating `CanActAsK9Handler`'s server-side equivalent — a direct `HasK9Access(src)` call, no client-side-only-convention issue exists server-side — for the throw path, and `IsConfiguredK9Model(GetEntityModel(GetPlayerPed(src)))` + `HasK9Access(src)` for the pickup path, reusing `server/certifications.lua`'s already-globally-exposed `IsConfiguredK9Model`, the same reuse `server/partnership.lua` already established for its own K9-role eligibility check), the `maxBallLifetimeMs` safety-valve sweep, and `playerDropped`/`onResourceStop` cleanup — all directly modeled on `server/kennel.lua`'s own shipped pattern, not re-derived from scratch. **One deliberate divergence from `kennel.lua`'s `confirmKennelPlaced`, disclosed, not a regression:** the confirm step here does **not** tightly re-validate the reported entity's position against the server-chosen spawn point the way `KENNEL_CONFIRM_DISTANCE_TOLERANCE` does — a kennel is a static placed object with a sensible position tolerance, but a *thrown, physics-simulated* ball's actual resting position legitimately moves far from its spawn point before the client even reports it (the research's own "treat a thrown ball's landing spot as a low-stakes, client-simulation-owned cosmetic fact" framing, since nothing server-authoritative — no currency, no evidence, no arrest — depends on where the ball ends up). The confirm step still validates entity existence, correct model, and that a matching pending-throw record exists and hasn't expired. |
| `config.lua` | **Extends** | Adds §14.2's tables verbatim. |
| `fxmanifest.lua` | **Extends** | Adds `client/proximityaudio.lua`, `client/attachments.lua`, `client/fetch.lua` to `client_scripts`; `server/fetch.lua` to `server_scripts`, loaded after `server/cooldowns.lua` (`NewCooldown` at file-load time) and `server/certifications.lua` (`HasK9Access`/`IsConfiguredK9Model` reuse) — same ordering-comment convention every other new server file in this manifest already carries. `dev/bone_sweep.lua` is **not** added anywhere in this manifest. |

---

## 14.4 — Per-feature detailed spec

### 14.4.1 Proximity Audio FX (`Config.Features.ProximityAudioFX`)

**Concrete behavior:**
- Requires `Config.Features.BasicBarkSounds` also `true` (layering
  convention, matching `Config.Features.AdvancedBarkRadial`'s own
  dependency on the same flag).
- While enabled, on the K9 player's own client, a tick loop
  (`Config.ProximityAudioFX.tickMs`) evaluates
  `Config.ProximityAudioFX.SuspectDistanceSource()`. If it returns `nil`, or
  a number beyond the last configured tier's `maxDistanceMeters`, nothing
  happens this tick.
- Otherwise, the loop finds the nearest-matching tier (by
  `maxDistanceMeters`, ordered nearest-to-farthest per §14.2's config) and,
  if at least that tier's own `cadenceMs` has elapsed since this tier last
  fired, sends `qbx_k9unit:server:relayGrowl(growlType)`.
- The server (`server/main.lua`'s new handler) re-validates
  `Config.Features.ProximityAudioFX AND Config.Features.BasicBarkSounds`,
  length-caps `growlType` (`GROWL_TYPE_MAX_LENGTH`), re-checks
  `HasK9Access(src)`, consumes the independent `GrowlCooldown`
  (`Config.ProximityAudioFX.serverCooldownMs`), resolves the sender's own
  ped/netId (never a client-supplied one, matching `relayBark`'s exact
  discipline), and broadcasts `qbx_k9unit:client:playGrowl(netId, growlType)`
  to `-1` — the same "broadcast wide, let the audio engine's own 3D
  distance-cull do the filtering" posture `relayBark`/`relayDoorScratch`
  already established, deliberately **not** the distance-filtered posture
  `server/search.lua`'s contraband-alert broadcast uses (a growl reveals no
  sensitive per-player/per-search information the way a search result
  does — nothing here needs scope-limiting beyond what native audio falloff
  already gives for free).
- Receiving clients play the sound via `PlaySoundOnNetworkEntity(netId,
  soundName)` — the exact same shared helper `playBark`/`playDoorScratch`/
  `playContrabandAlert` already use. `soundName` is resolved from
  `growlType` via a `GrowlTypeSoundNames` table built once at file load from
  `Config.ProximityAudioFX.distanceTiers`, mirroring `client/main.lua`'s own
  `BarkTypeSoundNames` construction pattern exactly. Every listener gets the
  game audio engine's own free, automatic 3D distance falloff relative to
  *their own* position — this is the "natural falloff as the listening
  player's own camera moves away from the K9" factor the original research
  flagged as already-free, and it requires no extra code on this native
  path (unlike the NUI/`GainNode` path, which would need it computed
  manually — a reason, not required by this spec but worth naming, to
  prefer the native path here over depending on an in-flight NUI audio
  bridge).
- **What this feature does NOT do, disclosed per §14.0 fork 2:** it does not
  detect a hidden suspect. `SuspectDistanceSource` ships `nil`. Until an
  operator supplies an implementation, this feature is real, wired
  plumbing that never fires.

**Reality check:** every native/event/cooldown/broadcast piece of this is
fully specified and buildable today with zero open questions. The one
thing this feature cannot do without further, separately-scoped design
work is decide what counts as a "hidden suspect" — that is explicitly out
of scope for this document, not an oversight.

**Acceptance criteria:**
- [ ] `Config.Features.ProximityAudioFX` defaults `false`; the tick loop in
      `client/proximityaudio.lua` registers nothing at all while
      `Config.Features.ProximityAudioFX AND Config.Features.BasicBarkSounds`
      is not both true (checked once at file-load, not per-tick).
- [ ] With the flag on and `SuspectDistanceSource` left `nil` (the shipped
      default), the feature is observably inert: no growl ever plays, no
      error is thrown, no console spam.
- [ ] With the flag on and `SuspectDistanceSource` wired to return a
      number, a growl fires at the tier matching that distance, at that
      tier's own `cadenceMs`, audible (subject to real audio assets
      existing) to any nearby player via the existing bark-audio pipeline,
      each hearing it at a volume determined by their own live distance to
      the K9 (native engine falloff).
- [ ] `qbx_k9unit:server:relayGrowl` independently re-validates the feature
      flag, `HasK9Access(src)`, `growlType`'s type and length
      (`GROWL_TYPE_MAX_LENGTH`), and its own `GrowlCooldown` — none of these
      checks are shared with `relayBark`'s equivalents (separate table,
      separate constant, per §14.0 fork 4).
- [ ] A player manually using the "Bark" radial item while
      `ProximityAudioFX`'s automatic growl loop is also active experiences
      no cross-throttling between the two — each has its own budget.
- [ ] No new server-authoritative consequence (currency, items, arrest
      progress, XP) is ever gated on this feature firing or not — it is
      purely a cosmetic/ambient audio cue, matching every other bark-family
      sound in this resource.

**Open questions:**
- The real "hidden suspect" detection primitive itself — explicitly
  deferred, not decided here (§14.0 fork 2). A future dedicated design pass
  would need to answer: who flags a ped "hidden" (crouch check? a
  foliage/prop-proximity heuristic? a manual player action to "start
  hiding," mirroring a hide-and-seek gamemode?), whether it's
  server-authoritative or a client heuristic, and whether it's pull-based
  or push-based — none of which this document guesses at.
- Real growl/pant audio asset sourcing — the same named, not-yet-resourced
  task `AdvancedBarkRadial` already needs (`phase2_notes/
  RESEARCH_ARCHIVE.md#phase-5-research` §1), not a new or larger ask created by this
  feature.

### 14.4.2 Prop Attachments (`Config.Features.PropAttachments`)

**Concrete behavior:**
- Config-driven list of "slots" (`Config.PropAttachments`, §14.2), each
  rendered as its own context-sensitive Equip/Unequip radial item nested
  under a new "Equipment" submenu opener inside the existing "K9 Unit"
  wheel — built from the config list exactly the way `client/radial.lua`'s
  existing `AdvancedBarkRadial` submenu is built from `Config.
  AdvancedBarkRadial`.
- Self-administered, purely client-side, **zero new server event**. This is
  a deliberate design decision, not an oversight — see the trust-model
  rationale immediately below.
- On Equip: resolves `Config.K9BoneIndices[currentModel][slot.boneField]`.
  If a real index has been recorded (fork 1's sweep ran for this model),
  attaches `CreateObject(slot.propModel, ...)` to the K9's own ped at that
  bone index via `AttachEntityToEntity` (mirrors `client/vehicle.lua`'s
  exact call shape). If that index is still `nil` for this model, falls
  back to bone index `0` (root) plus
  `Config.K9BoneFallbackOffsets[slotCategory]` — the same
  root-bone-plus-offset approximation `client/vehicle.lua` already uses for
  a different purpose, now disclosed as this feature's own documented
  fallback rather than a silent guess. If `slot.propModel` is `nil` (the
  shipped default, per fork 3 — no real prop name exists yet), Equip
  notifies "not configured" and does nothing, logging once server-console-
  side per this resource's established "disclosed, not silent" convention
  (`client/kennel.lua`'s own fallback-used breadcrumb print is the direct
  precedent).
- On Unequip: `DetachEntity` + `DeleteEntity` the tracked local object
  handle. Also runs on model swap, K9 vehicle entry/exit, disconnect, and
  `onResourceStop` — mirrors `client/vehicle.lua`'s own persisted-native-
  -state cleanup precedent (frozen/invisible/attached states that do not
  revert on their own just because a resource restarts).
- **Trust-model decision, made explicitly here, not left ambiguous:** gated
  by `CanShowK9UI()` only (the same client-cached, server-backed check
  every other radial item already relies on) — no dedicated server event,
  no server-side registry. This directly extends `client/vehicle.lua`'s
  own already-shipped, already-accepted precedent: that file's K9-in-vehicle
  `AttachEntityToEntity` call is executed **purely client-side, with zero
  server round trip**, for the same class of action (attaching something to
  the acting player's own already-controlled ped, with a stake to that same
  player and nobody else). This is deliberately **not** treated as
  `DeployableKennel`'s pattern (full server-computed-coords + confirm +
  registry), because a kennel is a **freestanding world object** that can
  independently outlive its placer's own session (exactly why it needs a
  registry, per `server/kennel.lua`'s own header) — a worn prop has **no**
  independent existence: it lives and dies exactly with the K9 player's own
  ped, the same way the K9's own visibility/collision/attach state during a
  vehicle ride does, needing no separate persistence/cleanup registry of
  its own. **Disclosed limitation of this choice, not hidden:** there is no
  server-side re-check preventing a player who loses `HasK9Access` *while
  already equipped* from staying visually equipped until they manually
  toggle it off — this mirrors `client/vehicle.lua`'s own existing
  "no forced eject on later decertification" posture for vehicle entry
  (no precedent in this codebase forces a K9 out of a vehicle mid-ride on a
  cert revoke either), accepted here for the same reason: purely cosmetic
  stakes, no gameplay-value or trust-boundary consequence riding on it.
- "Tracking camera" (one possible slot) is **cosmetic only** in this spec —
  explicitly, deliberately no functional link to any live camera feed.
  `CameraFeedPiP` is out of this document's scope entirely and was
  independently concluded impossible for a true inset feed
  (`phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` §6) — naming a slot
  "tracking camera" here ships a visual prop, nothing else, and this is a
  named non-goal to prevent scope creep, not an implied roadmap item.

**Reality check:** the attach mechanism itself needed zero new research —
it was already proven, in this exact codebase, before this document was
written. The two real remaining gaps are both asset/data gaps, not
mechanism gaps: a real prop model name (fork 3, operator-supplied, no safe
placeholder exists) and a real per-model bone index (fork 1, a bounded
one-time sweep, not blocking the mechanism itself thanks to the disclosed
fallback offset).

**Event/callback contract:** none. Entirely client-local, per the trust-model
decision above.

**Acceptance criteria:**
- [ ] `Config.Features.PropAttachments` defaults `false`.
- [ ] Each configured slot appears as its own context-sensitive
      Equip/Unequip item, gated by `CanShowK9UI()`, nested under a new
      "Equipment" submenu opener in the existing K9 Unit radial wheel.
- [ ] Equipping a slot whose `propModel` is `nil` notifies the player and
      does nothing observable — no error, no crash, one console breadcrumb.
- [ ] Equipping a slot whose model has a resolved `Config.K9BoneIndices`
      entry attaches the configured prop at that exact bone; equipping on a
      model with an unresolved entry attaches at the documented root-bone-
      plus-offset fallback instead — never a crash, never a silently wrong
      position with no explanation in the code.
- [ ] Unequip (and every automatic cleanup trigger: model swap, K9 vehicle
      entry/exit, disconnect, `onResourceStop`) leaves no orphaned prop
      entity behind.
- [ ] At most one attached prop per configured slot per K9 at any time —
      re-selecting an already-equipped slot toggles it off, it does not
      spawn a duplicate.
- [ ] No server event of any kind is registered for this feature — verified
      by its own file plan (client-only).
- [ ] No player-facing copy for a "tracking camera" slot claims or implies
      any live video/feed functionality.

**Open questions:**
- The real prop model(s) — unresolved, operator-supplied, no safe generic
  placeholder identified by any research pass (fork 3).
- Whether nested attachment (prop → K9 ped → vehicle, if a player equips a
  prop and then loads the K9 into a vehicle via the existing
  `EnterNearestK9Vehicle`) renders/behaves correctly — genuinely untested
  by any research pass; flag for in-engine confirmation during
  implementation, don't assert either way.
- Whether a single `vestBoneIndex` per model needs an additional rotation/
  offset tuning pass beyond the raw index itself (breeds have different
  builds) — deferred to the fork 1 sweep session itself to determine
  empirically, not decided here.

### 14.4.3 Fetch Mechanic (`Config.Features.FetchMechanic`)

**Concrete behavior:**
- **Throw** (a *handler* action, per `SPEC.md`'s own "on a handler command"
  wording — the thrower need not be riding a K9 model): a new radial item,
  "Throw Fetch Ball," gated by the new `CanActAsK9Handler()` (§14.3 — a
  deliberate, disclosed departure from every other radial item's
  `CanShowK9UI()` gate, since a human handler is expected to trigger this,
  not necessarily a second K9). Sends
  `qbx_k9unit:server:requestThrowFetchBall()`. Server re-validates
  `Config.Features.FetchMechanic`, `HasK9Access(src)`, the per-source
  `Config.FetchMechanic.throwCooldownMs`, and the one-active-ball-per-
  thrower-citizenid limit (mirrors `server/kennel.lua`'s
  `Kennels[citizenid]` shape and its own "per-actor, not per-area"
  reasoning verbatim), then computes a spawn point (thrower's live position
  + forward vector + `Config.FetchMechanic.throwForwardOffsetMeters`/
  `throwUpOffsetMeters`) and a throw-force vector, and instructs the
  **same** client to create and throw the object — mirrors
  `server/kennel.lua`'s "why the server computes the placement coords, the
  client only executes" principle exactly, extended here to also cover the
  throw-force vector (the server picks the numbers, the client's own
  physics engine still simulates the resulting arc/bounce, which the
  server never re-verifies — see the next bullet for why not).
- The thrower's client `CreateObject`s the ball, `ApplyForceToEntity`s it
  (the one real, source-confirmed community precedent for this exact call
  shape, `fruitmob/murderface-pets`), and reports its netId back.
  `server/fetch.lua`'s confirm handler validates existence, correct model,
  and a live matching pending-throw record — **deliberately does not**
  tightly re-validate the reported position against the server-chosen
  spawn point (unlike `server/kennel.lua`'s `KENNEL_CONFIRM_DISTANCE_TOLERANCE`),
  because a thrown ball's actual resting position is inherently client-
  physics-simulated and legitimately moves before this confirm even fires —
  treated, per the research's own framing, as a low-stakes,
  client-simulation-owned cosmetic fact, since no server-authoritative
  consequence of any kind depends on exactly where the ball lands.
- **Pursue:** zero scripting. The K9 player walks to the visible ball under
  their own completely normal native locomotion — the research's own
  headline finding, confirmed correct and adopted without modification:
  scripting an autonomous pursuit path for a real player's own ped would be
  the identical authority-mismatch category `PHASE3_SPEC.md` already hit
  and solved once (relaying effects to "the one actor already trusted for
  this action" rather than assuming script authority over an entity with
  its own real client) — here, the K9 player already *is* that trusted
  actor for their own movement, so there is nothing to build for this leg
  at all.
- **Pick up:** once within `Config.FetchMechanic.pickupInteractDistanceMeters`,
  an `ox_target` option ("Pick Up Ball," `addModel` by
  `Config.FetchMechanic.ballPropModel`'s hash — same pattern as
  `client/kennel.lua`'s "Pick Up Kennel" option) appears, gated by
  `CanShowK9UI()` (the K9-player-specific gate — only a K9 model carries
  anything in its mouth). `onSelect` sends
  `qbx_k9unit:server:requestPickupFetchBall(netId)`. Server re-validates
  the feature flag, `HasK9Access(src)`, and
  `IsConfiguredK9Model(GetEntityModel(GetPlayerPed(src)))` (reusing
  `server/certifications.lua`'s already-globally-exposed helper, the same
  reuse `server/partnership.lua` already established for an identical
  eligibility check), plus that the reported ball is genuinely the
  citizenid's own currently-active, not-yet-carried ball.
- **Carry:** branches on `Config.FetchMechanic.mouthCarryModeByModel[currentModel]`:
  - `'attach'` (only valid for a model whose fork-1 sweep found a usable
    `mouthBoneIndex` **and** whose bark/pant-scenario clipping check
    passed): the K9's own client calls
    `NetworkRequestControlOfEntity(ball)` (best-effort — the ball may have
    been created by a *different* client, the thrower's, not the K9's own;
    this exact prerequisite is already confirmed and in real use in this
    codebase's `client/combat.lua`) followed by `AttachEntityToEntity` at
    the resolved mouth bone. **A one-shot attach is sufficient here — this
    is a deliberate, disclosed contrast with `PropDragging`'s every-tick
    reassertion requirement** (`PHASE3_SPEC.md` §12.0 item 8's "new
    finding"): that discipline exists specifically because a hostile drag
    *target* has an active incentive to self-detach and escape; a K9
    player carrying their own fetched ball has no adversarial party working
    against the attach persisting, so there is no analogous threat model
    requiring per-tick reassertion here.
  - `'fake'` (the default for every model until explicitly upgraded — the
    real, source-confirmed `fruitmob/murderface-pets` precedent, legitimized
    by the research as a first-class option, not a compromise): on pickup,
    `DeleteEntity`s the world ball and plays a carry-appropriate animation/
    scenario on the K9 (candidate: reusing the existing
    `WORLD_DOG_BARKING_*` scenarios is **not** confirmed appropriate for a
    "carrying something in mouth" pose by any research pass — flagged as a
    genuinely open question below, not assumed). Tracks "is fake-carrying"
    client-side only.
- **Drop:** a second "Pick Up/Drop Ball" radial toggle item (same
  context-sensitive toggle shape as Attach/Detach Leash and Bite & Hold /
  Release) — releases wherever the K9 currently stands. For `'attach'`
  mode: `DetachEntity`. For `'fake'` mode: `CreateObject`s a fresh ball at
  the K9's current position. Either way, frees the thrower's one-ball slot
  server-side and ends the "fake-carrying" local state if applicable. **No
  "return to handler" objective or navigation requirement of any kind** —
  not named in `SPEC.md`, explicitly not added here as scope creep.
- **Lifecycle/cleanup:** `Config.FetchMechanic.maxBallLifetimeMs` safety
  valve force-despawns an un-dropped ball and frees its thrower's slot if
  it's never picked up or dropped (mirrors this resource's own "no
  unbounded state" discipline — `LEASH_REQUEST_TTL_MS`,
  `pendingPlacementTtlMs` — applied here to a world object's total
  lifetime rather than a pending request's). `playerDropped` and
  `onResourceStop` cleanup mirror `server/kennel.lua`'s own two-handler
  pattern (a still-connected client's own `onResourceStop` cleans up its
  own creation; the server's own sweep catches a ball whose creator already
  disconnected earlier in the session) exactly, adapted for "thrower" and
  "carrier" both being possible owning roles rather than kennel's single
  "handler" role.

**Reality check:** spawn/throw/pursue/pickup/drop/lifecycle are fully
native-only, have two real, complementary precedents to draw from (the
throw-impulse shape from `fruitmob/murderface-pets`, the full spawn/confirm/
cleanup lifecycle shape from this resource's own already-shipped
`kennel.lua` pair), and have zero open native-availability questions. The
one genuinely open piece — mouth-carry fidelity — already has a safe,
zero-asset, zero-bone-dependency default (`'fake'` mode) that ships the
entire rest of the feature working regardless of fork 1's outcome.

**Event/callback contract:**
- `qbx_k9unit:server:requestThrowFetchBall` () [client→server]
- `qbx_k9unit:client:throwFetchBallAt` (spawnX, spawnY, spawnZ, forceX,
  forceY, forceZ: numbers) [server→client, thrower only]
- `qbx_k9unit:server:confirmFetchBallThrown` (netId: number) [client→server]
- `qbx_k9unit:server:requestPickupFetchBall` (netId: number) [client→server]
- `qbx_k9unit:client:carryFetchBall` (netId: number, mode: 'attach'|'fake')
  [server→client, picking-up K9's own client only]
- `qbx_k9unit:server:releaseFetchBall` () [client→server, either the
  current carrier or — mirroring every other toggle-shaped action in this
  resource's radial (Detach Leash, Bite & Hold's Release, Drag's Release)
  — **not gated on `CanShowK9UI()` on the way out**, so a K9 that loses
  access mid-carry can still let go]

**Acceptance criteria:**
- [ ] `Config.Features.FetchMechanic` defaults `false`.
- [ ] "Throw Fetch Ball" is available to any player passing
      `CanActAsK9Handler()` (`HasK9Access()` alone), independent of whether
      that player is currently riding a K9 model.
- [ ] A thrown ball is a real, spawned, physics-simulated `prop_tennis_ball`
      (or `Config.FetchMechanic.ballPropModel`, if changed) visible to every
      nearby client, with zero additional assets required.
- [ ] A K9 player can walk to the ball using nothing but their own native
      locomotion — no scripted pursuit task of any kind exists anywhere in
      this feature.
- [ ] "Pick Up Ball" only appears/succeeds for a player passing
      `CanShowK9UI()` server-side re-verified via `IsConfiguredK9Model` +
      `HasK9Access`.
- [ ] Carrying a ball in `'attach'` mode visibly follows the K9's mouth
      region; carrying in `'fake'` mode deletes the world object and shows
      a carry animation/scenario instead — the active mode for the current
      model is never ambiguous or mixed mid-carry.
- [ ] Dropping releases the ball at the K9's current position in both
      modes, with no "return to handler" requirement.
- [ ] At most one active (thrown-but-not-yet-dropped) ball per thrower
      citizenid; a second throw attempt while one is still active is
      rejected with a notification, not silently queued or duplicated.
- [ ] An un-dropped ball is force-despawned after
      `Config.FetchMechanic.maxBallLifetimeMs` and its thrower's slot frees
      up — verified by direct test, not just by the config value existing.
- [ ] Disconnect (either the thrower's, mid-pending-throw, or the
      carrier's, mid-carry) and `onResourceStop` both leave no orphaned
      ball entity behind.
- [ ] `Config.FetchMechanic.mouthCarryModeByModel` defaults every
      `Config.Peds` model to `'fake'` — no model ships in `'attach'` mode
      without an explicit, disclosed edit following a real fork-1 sweep +
      clipping check for that specific model.

**Open questions:**
- Whether `'fake'` mode's carry animation should reuse the existing
  `WORLD_DOG_BARKING_*` scenarios (untested for this specific "carrying
  something" visual intent) or needs a different, currently-unidentified
  vanilla clip — genuinely open, no source found by any research pass names
  a confirmed "quadruped carrying an object in its mouth" vanilla
  animation.
- Fork 1's sweep outcome per model (whether any model ever qualifies for
  `'attach'` mode at all) — unresolved until that session runs.
- An "evidence bag" prop as a named `SPEC.md` §6.7 alternative to
  `prop_tennis_ball` — not attempted, not required for v1, purely a future
  content-sourcing decision.

---

## 14.5 — Cross-cutting notes carried forward

- **Config-validator pass required before any of these three flags default
  to `true`** on a live server — every numeric placeholder in §14.2
  (`distanceTiers`' cadences/distances, `throwForce*`/`throwCooldownMs`/
  `maxBallLifetimeMs`, `pickupInteractDistanceMeters`) is an unreviewed,
  reasonable-looking guess, same status every prior phase's own config
  sketch carried into its own review gate.
- **Asset-pipeline coordination required for two of three features before
  they ship a real, non-placeholder experience** — see §14.0 fork 3's table
  for exactly what's missing per feature; none of the three gaps are new
  categories of gap this document introduces, all trace directly to
  already-named, already-tracked asset needs (`SPEC.md` §7/§9 item 7,
  `phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research` §1).
- **`ProximityAudioFX`'s `SuspectDistanceSource` and `PropAttachments`'
  `propModel` are both, deliberately, "we cannot resolve this ourselves,
  here is the seam" integration points**, not partially-implemented
  features — this mirrors `SPEC.md` §2's own explicit non-goal posture
  ("exports/events will be exposed so such integration is possible, but no
  particular external resource is assumed to exist") applied to two new
  cases, not a new philosophy invented for this document.
- **Nothing in this document depends on the specific implementation of any
  in-flight NUI audio bridge work** — `ProximityAudioFX` is specced against
  the existing, already-proven native `PlaySoundFromEntity` pipeline
  (reusing `relayBark`'s own broadcast/cooldown/playback shape almost
  verbatim), which needs no NUI involvement at all. If a real NUI audio
  bridge lands from other work, it remains a legitimate future upgrade path
  for continuous (rather than discrete-tier) volume scaling — not assumed,
  not required, not blocking this spec's acceptance criteria.

---

## 14.6 — Quick-reference: decisions that must be made before implementation starts

1. **Fork 1 (bone-index sweep) — RESOLVED as a concrete, bounded engineering
   procedure**, not a design decision left open: run `dev/bone_sweep.lua`
   once per `Config.Peds` model, record `vestBoneIndex`/`mouthBoneIndex`
   into `Config.K9BoneIndices`, with a documented, safe fallback for any
   model where no real bone is found. Unlocks `PropAttachments` (§14.4.2)
   and `FetchMechanic`'s `'attach'` carry mode (§14.4.3) — neither is fully
   blocked on it, both degrade gracefully without it.
2. **Fork 2 (`ProximityAudioFX`'s hidden-suspect detection) — RESOLVED as a
   deliberate deferral**: this document does not build a live "is this ped
   hidden" primitive. The audio-delivery mechanism ships fully real and
   buildable; the trigger condition ships as an explicit, `nil`-by-default
   `SuspectDistanceSource` hook with no default implementation, honestly
   inert until an operator (or a future, separately-scoped design pass)
   wires it.
3. **Fork 3 (asset dependency) — RESOLVED as an explicit per-feature
   disclosure**, not silently assumed either way: `FetchMechanic` ships
   fully functional with zero new assets; `PropAttachments` ships with the
   mechanism real but no visible prop until an operator supplies one (no
   safe placeholder guessed, unlike `DeployableKennel`'s); `ProximityAudioFX`
   ships with the same safe placeholder-audio posture `AdvancedBarkRadial`
   already has, plus its own separate, larger gap (fork 2).
4. **Fork 4 (`ProximityAudioFX`'s cooldown) — RESOLVED**: a new, independent
   event/cooldown pair (`relayGrowl`/`GrowlCooldown`), not a reuse of
   `relayBark`'s, mirroring `relayDoorScratch`'s own already-established
   "independently cooldowned action" precedent.
5. **`PropAttachments`' trust model — RESOLVED**: purely client-side, no
   server event, directly extending `client/vehicle.lua`'s own
   already-shipped precedent for "attach something to my own already-
   controlled ped, zero stake to anyone else." Disclosed limitation: no
   forced unequip on later decertification, matching vehicle-entry's own
   existing posture.
6. **`FetchMechanic`'s throw-gate — RESOLVED**: a new client-side
   combinator, `CanActAsK9Handler()` (`client/main.lua`), used instead of
   `CanShowK9UI()` for the "Throw" trigger only, since `SPEC.md`'s own
   "handler command" wording implies a human handler distinct from the K9
   itself — a deliberate, disclosed, narrow departure from this resource's
   otherwise-universal radial-item gate, not an inconsistency.
7. **`FetchMechanic`'s mouth-carry fidelity — RESOLVED as a safe default**:
   every model ships in `'fake'` (delete-and-animate) mode until fork 1's
   sweep and a bark/pant-scenario clipping check explicitly upgrade a
   specific model to `'attach'` mode — never the reverse, never a guess.

**Still genuinely open — content/asset/verification items, not design
decisions:**
8. Real growl/pant/vest/harness/camera-housing audio and prop assets — all
   already-named, not-yet-resourced content-sourcing tasks (§14.0 fork 3),
   not new asks this document invents.
9. Whether any `WORLD_DOG_BARKING_*` scenario is a visually acceptable
   stand-in for `FetchMechanic`'s `'fake'`-mode carry pose — untested,
   flagged, not assumed either way (§14.4.3).
10. The real "hidden suspect" detection primitive itself, and every design
    question under it (who flags a ped hidden, how, server- or
    client-observed) — explicitly out of this document's scope (§14.0
    fork 2), a precondition for a future `ProximityAudioFX` v2, not a task
    this pass leaves half-done.
