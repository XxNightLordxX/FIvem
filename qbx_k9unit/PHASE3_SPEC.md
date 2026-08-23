# qbx_k9unit — Phase 3 Detailed Spec (Combat, Takedowns & Advanced Agility)

Status: **planning only, work-ahead of implementation — no `.lua` file in this
resource has been touched to produce this document.** Written while Phase 2
(`ScentTracking`/`BloodTracking`/`WaterTrackingDecay`/`GunpowderSniffing`/
`SearchZones`/`ContrabandAlerts`/`ThermalVision`/`NightVision`/
`DoorInteraction`) is mid-implementation by other agents, per explicit
direction not to touch any Phase 2 file. Grounded in a full read of
`SPEC.md` (all sections, especially §2 scope, §6.2's existing high-level
Phase 3 bullets, §7's native-only-approximation table, §8's phased build
plan, §9's open questions — especially item 5, the PvP-balance flag this
document expands on rather than resolves), `config.lua`'s already-placeholder
`Config.Features.BiteAndHold` / `NonLethalTakedown` / `HandlerDownDefense` /
`PropDragging` / `AgilityAdvanced` flags, and the actual shipped Phase 1 code
(`client/main.lua`, `client/movement.lua`, `client/radial.lua`,
`client/vehicle.lua`, `server/main.lua`, `server/certifications.lua`,
`fxmanifest.lua`) plus the Phase 2 files as they exist right now
(`config.lua`'s Phase 2 tables, `phase2_notes/*.md`) for pattern precedent —
**read, never edited**.

Author: product-agent, 2026-08-23, jlwood17190665@gmail.com.

## Relationship to `SPEC.md` and to this project's document-scale precedent

This document is written to become `SPEC.md` §12 (immediately after §11,
Phase 2's own detailed spec) once someone with safe incremental-edit access
to that file folds it in — it deliberately uses `§12.x` numbering internally
for that reason. It is **not** folded into `SPEC.md` directly in this pass:
`SPEC.md` is already ~1,500 lines, this agent's toolset here has no
line-level edit capability (only whole-file read/write), and reconstructing
the entire existing file from a read-back to append one section is a real,
avoidable risk of silently corrupting reviewed, shipped content for zero
benefit over a new file. This project already has clear precedent for
exactly this situation: `REFACTOR_ROADMAP.md`, `FEATURE_IDEAS.md`,
`WATCHDOG_LOG.md`, and every file under `phase2_notes/` are all standalone
documents that supplement (not replace) `SPEC.md`, each explicitly
cross-referencing back to the section(s) they extend rather than requiring an
edit to `SPEC.md` itself to be authoritative — this document follows that
same convention. Until it is folded in, treat it exactly the way
`phase2_notes/contraband_search_contract.md` treats its own relationship to
§11: **authoritative detail that supplements, and where more specific
supersedes, `SPEC.md` §6.2/§7/§8/§9's existing Phase 3 text** — reconcile
against `SPEC.md` directly if the two ever drift.

**Read §12.0 first.** Unlike Phase 2 (where §11.1's sub-phase ordering was
the main structural decision needed up front), Phase 3 has several
architecture-level forks that change file plans, config schema, and event
contracts materially depending on the answer — flagged explicitly, per this
task's own instruction, rather than guessed. **No `Config.Features` flag in
this phase should be flipped to `true` on a live server, and no
implementation should start past a design-review pass, until §12.0's items
are answered by a human decision-maker or an explicitly delegated
specialist** (coder-security / config-validator, per §12.6).

---

## 12.0 — Blocking, cross-cutting open questions (read this first)

### 1. PvP vs. PvE target scope — blocks all four target-taking mechanics

`SPEC.md` §6.2's own wording ("target ped/player," "fleeing (sprint-state)
suspect," "nearest hostile," "downed ped") never actually commits to whether
BiteAndHold, NonLethalTakedown, PropDragging, and HandlerDownDefense's
"nearest hostile" can target other **players'** characters, only
AI-controlled **NPC** peds, or both. This is not a wording nitpick — it is
the single most expensive fork in this phase:

- An **NPC target** can be commanded directly by any client that holds (or
  requests via `NetworkRequestControlOfEntity`) network ownership of that
  entity: `TaskRagdollPed`, forced anim/task natives, `SetEntityCoords`/
  `AttachEntityToEntity`, and AI-behavior natives (`SetBlockingOfNonTemporaryEvents`,
  `SetPedFleeAttributes`, etc.) all work, because the entity has no
  independent client of its own insisting on its own state.
- A **player target cannot be reliably controlled this way at all.**
  FiveM's networking model gives every player's own client final authority
  over its own ped's position and control-input state.
  `DisableControlAction` only ever affects the **local** client calling it;
  attempting to force another player's controls or position from a third
  client fights the network and either desyncs or silently does nothing.
  The only correct architecture for a player target is the one this
  codebase already established for the leash mechanic
  (`client/movement.lua`'s own header: *"a client can only reliably control
  its own ped's position... you cannot dependably force another client's
  ped to a position from here"*) — the server relays an instruction to the
  **target's own client**, and that client applies the effect to itself
  (self-disabling sprint/fire, self-ragdolling, self-attaching to the K9 for
  a drag). This is a materially bigger, more security-sensitive build than
  the NPC case, and it carries an inherent, **non-closable** limitation: a
  modified/malicious client on the target's side can simply ignore the
  incoming "you are bitten/ragdolled/dragged" instruction and keep moving or
  firing normally. This is the same class of trust gap every FiveM resource
  that ever applies state to a *remote* player already accepts as a known
  limitation (no different in kind from an existing cuff/taser resource) —
  worth naming explicitly here rather than discovering it mid-implementation.
- **This document cannot pick an answer.** It changes whether
  `server/combat.lua` needs a whole client-relay-and-cooperate subsystem per
  action (structurally close to the leash's request/effect shape, minus
  consent — see item 2 below) or a much simpler direct-entity-command path;
  whether "downed"/"fleeing" detection reads native ped state (NPC) or must
  be inferred from relayed telemetry (player); and whether PropDragging is
  meaningfully different from a reskinned leash mechanic (player target) or
  a simple attach-and-move (NPC target).

**Recommendation, not a decision:** scope Phase 3's first ship to **NPC (AI
ped) targets only** for all four target-taking mechanics, and treat
player-vs-player K9 combat as a distinct, separately-scoped extension
requiring its own dedicated security review (the client-cooperation caveat
above is a much bigger real-world concern in PvP than against an NPC, where
there is no "modified client" on the other end to worry about). This halves
near-term implementation cost and sidesteps the worst of the trust-gap
concern — but it is a real, visible functionality reduction from a literal
reading of `SPEC.md` §6.2's wording ("target ped/player," "suspect,"
"hostile"), so it needs explicit sign-off, not a silent pick.

### 2. Non-consensual state application — a deliberate reversal of the Phase 1 leash precedent

The leash mechanic's hardest-line rule was *"nobody can be leashed without
agreeing to it first"* (`SPEC.md` §6.1, §9 item 3b). BiteAndHold /
NonLethalTakedown / PropDragging are, by design intent (apprehending a
suspect), supposed to work **without** the target's consent — a fleeing
suspect will obviously never consent to being bitten. This isn't a logical
contradiction (the leash's consent rule protects a *willing* participant's
own movement; Phase 3's actions exist specifically to constrain an
*unwilling* one), but it's a real values/design-posture shift for this
codebase, worth an explicit sign-off rather than a silent carry-over
assumption — especially if item 1 above ever puts real players in scope,
where "apply an uncancellable hostile state to another real player's
character with no consent step" is a materially different trust/abuse
posture than anything Phase 1/2 shipped.

### 3. Target-eligibility restriction, independent of PvP-balance tuning

`SPEC.md` §9 item 5 already flags a PvP-balance/cooldown review as needed
before default-enabling Phase 3 — that's about exploit/spam prevention. A
separate, unaddressed question: should these actions be blocked from
targeting players who are **themselves** in `Config.Departments` (e.g., to
prevent bite-holding a fellow officer as a prank/griefing vector), or is
that left entirely to server RP/admin norms, the way most cuff/taser
resources in this ecosystem leave "who gets cuffed" undecided at the code
level? Not resolved here — distinct enough from the balance-cooldown
question that it shouldn't be silently folded into it.

### 4. Does combat require an established handler partnership, or is the K9 fully autonomous?

Bite-and-hold's own description ("until the handler issues a Recall")
implies a handler exists and can issue commands, yet the leash pairing
(`server/main.lua`'s `LeashPairs`) is the **only** existing "K9 ↔ handler"
link in this codebase, and it is optional, ephemeral, and currently
unrelated to anything combat-shaped. Handler-down defense explicitly needs
*some* persistent notion of "who is this K9's handler" to know whose health
to watch. Two real options:

- **(a) Reuse the active leash pairing as-is** (recommended default, not
  decided): zero new persistent state, but a real functional limitation — a
  K9 deliberately off-leash during a foot chase (arguably the *more* common
  real scenario) gets no defense-mode support.
- **(b) A new, longer-lived "K9 partnership" registry**, independent of
  leash state (e.g., set once via a radial "Partner With" action, persisting
  until explicitly broken or either side goes off-duty) — closer to what
  "handler" probably means intuitively for this feature, but a real new
  piece of infrastructure this document has not designed.

Resolving this once affects both BiteAndHold's "Recall" actor (§12.5.1) and
HandlerDownDefense's handler-lookup (§12.5.3) — flagged once here, applied
per-feature below.

---

## 12.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| **3a — independent, start immediately** | `AgilityAdvanced` | Pure client-local own-body movement (extends `client/movement.lua`'s existing `AgilityBasicJump` precedent) — does not touch target/combat logic, has no dependency on §12.0's forks at all. Good first ticket regardless of how §12.0 resolves. |
| **3b — foundational, blocked on §12.0 items 1/2/4** | `BiteAndHold` | Establishes the target-effect relay pattern (NPC-direct-command or player-relay-and-cooperate, per §12.0 item 1) and the shared hold/incapacitate ephemeral state + Recall actor (§12.0 item 4) every later combat feature either reuses or mirrors. |
| **3c — depends on 3b's target infra** | `NonLethalTakedown` | Reuses whatever target-effect relay shape 3b establishes; additionally needs new "recent speed history per targetable entity" server state not built by anything else in this codebase yet (§12.5.2). |
| **3d — depends on 3b/3c's target infra AND an external integration decision** | `PropDragging` | Cannot be scoped concretely until the target server's "is this player downed" integration point is confirmed (§12.5.4) — this is a genuine external dependency, not an ordering preference. |
| **3e — depends on Phase 2's tracking infra AND §12.0 item 4** | `HandlerDownDefense` | Reuses Phase 2's `server/tracking.lua` damage-event log rather than building a second one, and is a pure consumer of 3b/3c's own target-action paths (it only pre-selects a target, it doesn't add a new privileged action). Land last — it has no infra of its own to contribute, only to consume. |

---

## 12.2 Config schema additions (sketch)

New top-level `Config.Combat` table, in the same style as existing blocks
(banner comments, inline rationale). **Every numeric value below is an
unreviewed placeholder** — flagged explicitly for a PvP-balance /
config-validator pass (`SPEC.md` §9 item 5, expanded by §12.6 below) before
any of this is wired to real code, exactly the same status Phase 2's
`Config.SearchContrabandItems` / `Config.ContrabandAlertTiers` shipped with.

```lua
-- ======================================================================
-- PHASE 3 — COMBAT & ADVANCED AGILITY. Every leaf feature independently
-- gated by its own Config.Features flag (already present as placeholders).
-- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
-- PvP-balance/config-validator pass (SPEC.md §9 item 5) -- do not treat any
-- of these as tuned, and do not default-enable the owning feature before
-- that review, per PHASE3_SPEC.md §12.0/§12.6.
-- ======================================================================
Config.Combat = {
    BiteAndHold = {
        range            = 2.5,    -- meters, self-initiated trigger range
        maxDurationMs    = 15000,  -- hard timeout if never manually released/recalled
        cooldownMs       = 20000,  -- per-K9 cooldown between attempts
    },
    NonLethalTakedown = {
        range            = 3.0,
        minTargetSpeed   = 4.0,    -- m/s, SERVER-COMPUTED from position samples -- never a client-claimed "I am sprinting" flag, see §12.5.2
        cooldownMs       = 25000,  -- per-K9 cooldown
        targetCooldownMs = 30000,  -- per-target cooldown -- stops repeat takedowns of the same already-downed target by multiple K9s in quick succession, see §12.5.2
        healthFloor      = 100,    -- backstop only, NOT the primary non-lethal mechanism -- see §12.5.2 for why fall-damage suppression must be the primary one
    },
    HandlerDownDefense = {
        handlerHealthThreshold  = 100, -- needs review against this server's real max-health/downed-system numbers, see §12.5.3
        triggerRadius           = 15.0, -- max distance from the handler for the partner K9 to receive the defense-mode prompt
        hostileLookbackSeconds  = 10,   -- "hostile" = whoever last damaged the handler within this window, reusing Phase 2's relayDamageEvent log
    },
    PropDragging = {
        range               = 2.0,
        dragSpeedMultiplier = 0.6,
        maxDragDistance     = 30.0, -- safety-valve auto-release distance -- UNRELATED to Config.LeashMaxDistance, do not conflate
    },
    AgilityAdvanced = {
        detectionMethod = 'raycast', -- 'raycast' | 'taggedProp' -- see §12.5.5, NOT decided in this document
        maxVaultHeight  = 1.2,       -- meters
        vaultCooldownMs = 2000,
    },
}
```

---

## 12.3 File/module plan (sketch)

Continuing the trust-model-driven split precedent §11.3 established (e.g.
`client/tracking.lua` — cosmetic, no real capability — vs. `client/search.lua`
— a real capability grant — split by trust model, not just feature name):

| File | New/extends | Owns |
|---|---|---|
| `client/combat.lua` | **New** | BiteAndHold + NonLethalTakedown self-initiated triggers (radial item, local anim, calls the server callbacks below). Kept out of `client/movement.lua` for the same "don't let one file balloon" reasoning §11.3 already applied to `client/tracking.lua`/`client/search.lua` — these are real capabilities applied to another entity, not the K9's own body. |
| `server/combat.lua` | **New** | BiteAndHold + NonLethalTakedown server authority: re-validates access/range/target-scope/eligibility, computes the server-side speed gate for takedown (§12.5.2 — genuinely new state, not present anywhere in this codebase yet), applies the health floor, and owns the ephemeral "who's currently held/recalled" state (mirrors `LeashPairs`' shape/hygiene conventions in `server/main.lua` — disconnect cleanup, no unbounded growth). |
| `client/defense.lua` | **New** | HandlerDownDefense's client-side presentation **only** — per §12.0 item 4's recommended reading, this never remote-controls the player; it just streamlines target selection into the existing `client/combat.lua` action paths. |
| `server/defense.lua` | **New** | Hooks into `server/tracking.lua`'s **existing** damage-event log (Phase 2) rather than building a second one; watches for a partnered handler's health crossing `Config.Combat.HandlerDownDefense.handlerHealthThreshold` and, if a partnership link resolves (§12.0 item 4), notifies the partner K9's client. |
| `client/dragging.lua` | **New, or folded into `client/combat.lua`** | Depends on §12.0 item 1's answer: if NPC-only, this is small enough to fold in; if player targets are in scope, PropDragging is structurally closer to a hostile reskin of the leash mechanic (§12.5.4) and deserves its own file mirroring `client/movement.lua`'s leash section. Not decided here. |
| `client/movement.lua` | **Extends** | `AgilityAdvanced`'s vault trigger — same file, same "self, own body, native locomotion" category `AgilityBasicJump`'s existing suppression thread already lives in. |
| `config.lua` | **Extends** | Adds §12.2's `Config.Combat` table verbatim (pending the balance review flagged there). |
| `fxmanifest.lua` | **Extends** | Adds the new client/server files above to their respective script lists. |

`server/main.lua`'s own reserved-space comment (*"Reserved for future Phase
2+ small, access-gated K9 actions that need server authority but aren't part
of the certification/permission system itself"*) is **not** the right home
for any of this — combat/defense state is comparable in size to the leash
subsystem that already earned its own real estate in that file, not a
"small" action, so per the exact same "don't let one file balloon" logic
already used for Phase 2's `server/tracking.lua`/`server/search.lua`, Phase
3 gets its own new files.

---

## 12.4 — Per-feature detailed spec

### 12.5.1 Bite-and-Hold (`Config.Features.BiteAndHold`)

**Concrete behavior:**
- Trigger: the K9 player selects "Bite & Hold" from the K9 Unit radial
  (self-initiated — the K9 controls itself, not a handler-issued remote
  command) while within `Config.Combat.BiteAndHold.range` of an eligible
  target (NPC ped, per §12.0 item 1's recommended default scope), passing
  `CanShowK9UI()`.
- Effect: the K9 plays a latch/bite animation oriented at the target
  (attached near the target's arm/torso per `SPEC.md` §7's existing
  framing — no rigid physical bone attachment); the target enters a "held"
  state lasting up to `Config.Combat.BiteAndHold.maxDurationMs`, ending
  early on (a) the K9 player selecting "Release," or (b) — once §12.0 item
  4 is resolved — a recognized partner handler issuing "Recall," whichever
  comes first.
- While held (NPC target): the target's AI is suppressed via a forced
  anim/task-pause plus `SetBlockingOfNonTemporaryEvents`/
  `SetPedFleeAttributes` so it neither flees nor attacks meaningfully; no
  lethal damage is applied by the hold itself (see the open question below
  on whether *any* damage applies).
- While held (player target, **only if in scope per §12.0 item 1**): the
  target's own client receives a relayed instruction and self-applies
  `DisableControlAction` on sprint and weapon-fire controls for the
  duration; the K9's own client only plays its local anim and never
  directly enforces anything on the target's entity (§12.0 item 1's
  architecture requirement).
- One hold at a time per K9; a new bite attempt on a target already held by
  someone else is rejected server-side (`already_held`), never silently
  double-applied.

**Reality check:** unchanged conclusion from `SPEC.md` §7 — task/animation
plus a control-disable/AI-suppression state, not a literal rigid-body bite.
**New, not previously verified anywhere in this codebase:** no confirmed
generic "K9 bite/hold" anim/scenario has been located the way
`WORLD_DOG_SITTING_*` was found for Sit (`client/movement.lua`'s header
documents that verification pass explicitly). GTA V's story mode has Chop
attack an NPC in a specific mission context, suggesting *some* dog-attack
clip exists in game data, but **this was not verified this session** — flag
it honestly as unresolved, not as a confirmed asset, the same way
`client/movement.lua`'s header distinguishes "HIGH confidence" from "MEDIUM
confidence, untested in-engine" for its own sit-scenario mapping.

**Event/callback contract sketch:**
- `qbx_k9unit:server:requestBiteHold` (targetNetId: number)
  [client→server, `server/combat.lua`] — re-validates
  `Config.Features.BiteAndHold`, `HasK9Access(source)`, live proximity to
  the resolved entity (never a client-claimed distance — same
  step-ordering discipline as `contraband_search_contract.md`'s step 8),
  that the entity isn't already held, and the entity's real type against
  whatever target scope §12.0 item 1 settles on. On success: opens an
  ephemeral hold-state entry keyed by the K9's source (target netId/entity
  + expiry timestamp), broadcasts a cosmetic "played anim" event to nearby
  clients, and — only if the target is a player and player targets are in
  scope — sends the target's own client the self-suppress instruction.
- `qbx_k9unit:server:releaseBiteHold` () [client→server] — the holding K9
  (or, once §12.0 item 4 is resolved, the recognized partner handler) ends
  the hold early. Mirrors the leash's "ending it needs no consent, only
  starting it needed a check" shape — though note bite-and-hold's *start*
  needs no target consent at all (§12.0 item 2), unlike the leash's attach.
- Server-side timeout past `maxDurationMs` auto-clears the hold the same
  way the leash's hard-cap safety valve auto-detaches — reuse that pattern
  (a periodic sweep or per-hold `SetTimeout`), never a client-trusted "my
  timer expired" claim.
- **Never client-authoritative:** whether a hold is active, when it
  started/expires, and whether the target is currently suppressed are all
  server state. The target's own client self-applying
  `DisableControlAction` is the one piece of "enforcement" that must run
  client-side by necessity (§12.0 item 1's inherent, non-closable
  limitation) — everything else is server-decided.

**Open questions (blocking):**
- §12.0 items 1, 2, and 4 all apply directly.
- Exact bite/attack anim dict + clip name — not verified this session; a
  native-verification pass (the same class of source `movement.lua`'s Sit
  scenario already used) is needed before implementation, not a guess.
- Does a held target take any damage over the hold duration, or is it
  purely a control/mobility restriction with zero damage? `SPEC.md` §6.2's
  own wording ("interrupts the target's sprint/weapon-fire ability") reads
  as the latter — recommending that reading explicitly since it's simplest
  and matches the literal text, but flagging for a conscious sign-off
  rather than an unstated assumption, since a real K9-unit mechanic
  elsewhere in the ecosystem might reasonably expect some damage-over-time.

### 12.5.2 Non-lethal takedown (`Config.Features.NonLethalTakedown`)

**Concrete behavior:**
- Trigger: same self-initiated radial pattern as bite-and-hold, requiring
  the target to currently be "fleeing" — defined as **server-computed
  speed over the last few position samples exceeding
  `Config.Combat.NonLethalTakedown.minTargetSpeed`**, explicitly **not** a
  client-reported "I am sprinting" claim (a client-reported boolean is
  exactly the kind of client-supplied state that grants a capability this
  project's own established rule says never to trust). For an NPC target
  this is trivially computed server-side from consecutive
  `GetEntityCoords` polls (the server already has authoritative position
  for any networked entity). For a player target it requires either the
  same "target's own client relays its own telemetry" pattern Phase 2
  already established for `relayDamageEvent`/`relayWeaponFire`, or a
  server-side position-delta poll — not guaranteed to be cheap/available
  for an entity not otherwise network-relevant to the K9's own client.
- Effect: the K9 ragdolls/knocks the target down; no weapon/melee damage is
  applied by the action itself. `Config.Combat.NonLethalTakedown.healthFloor`
  is enforced server-side as a **backstop**, specifically because GTA's
  ragdoll physics can independently cause fall/impact damage as a side
  effect of a forced ragdoll — "without applying lethal damage" (`SPEC.md`
  §6.2) is best satisfied primarily by **suppressing fall damage** for the
  duration of the forced ragdoll (exact ped-config-flag/native TBD, not
  verified this session), with the health floor as a secondary
  belt-and-suspenders check, not the primary mechanism — a floor alone
  doesn't explain, in-fiction, why an already-low-health target being
  knocked down repeatedly never actually dies from the fall itself.

**Reality check:** `TaskRagdollPed`-based knockdown is fully native-only and
a well-established FiveM pattern — no asset gap here, unlike bite-and-hold's
anim uncertainty. The fall-damage-immunity flag/native needs its own
verification pass (not attempted this session) — flagged, not guessed.

**Event/callback contract sketch:**
- `qbx_k9unit:server:requestTakedown` (targetNetId: number)
  [client→server, `server/combat.lua`] — re-validates feature flag, access,
  live proximity, target-type/scope, **and** the server-computed speed gate
  (reject `not_fleeing` if recent speed samples don't clear
  `minTargetSpeed`). This is the one check in this whole document requiring
  the server to already track a short rolling position history per
  potentially-targetable entity — **genuinely new state this codebase does
  not have anywhere yet**, not an extension of anything Phase 1/2 built.
- Cooldown: per-K9 (`cooldownMs`, mirroring `BARK_COOLDOWN_MS`'s
  established shape) **and** per-target (`targetCooldownMs`, mirroring
  `contraband_search_contract.md` §4B's resolved-identity reasoning) — the
  per-target cooldown exists specifically to stop repeat takedowns of the
  same already-downed target by multiple K9s in quick succession, an
  obvious griefing vector against a target with no self-service recovery,
  arguably worse than the leash's already-solved "trap someone" problem
  since a downed target can't run away to dodge a second hit the way a
  still-fleeing target could dodge a first attempt.
- Ordering: the server must apply the health floor and (once resolved) the
  fall-damage suppression **before** triggering the ragdoll task — via the
  target's own client (player) or directly (NPC) — the same
  ordering-matters discipline `contraband_search_contract.md`'s
  proximity-before-inventory-read step already established for this
  codebase.

**Open questions (blocking):**
- §12.0 items 1, 2, 3 apply.
- The "rolling speed history per targetable entity" state is new
  infrastructure this document flags but does not design in detail —
  needs its own design pass (likely in `server/combat.lua`, possibly
  extending Phase 2's tracking-log shape) before implementation.
- Exact fall-damage-suppression native/flag — not verified this session.
- Should a takedown leave the target in a state some other resource's
  cuff/restraint system can pick up, or is it purely cosmetic with nothing
  left behind afterward? `SPEC.md` §9 item 5 already raises this generally;
  recommend exposing an export/event hook rather than assuming a specific
  cuff resource exists, consistent with this resource's own established
  non-goal precedent for bodycam integration (`SPEC.md` §2) — not decided
  here.

### 12.5.3 Handler-down defense (`Config.Features.HandlerDownDefense`)

**Critical non-goal to state up front:** *"the K9 automatically enters an
aggressive state ... with no manual radial input required"* (`SPEC.md`
§6.2) must **not** be read as this resource taking control of the K9
player's own movement/combat — that would directly conflict with `SPEC.md`
§2's own standing, explicit non-goal (*"this resource never spawns,
possesses, or remote-controls a K9 ped on anyone's behalf"*) and with §1's
*"The K9 player controls themselves directly, like any other player
character, at all times."*

**Recommended reading (ASSUMED, NOT DECIDED — flagged for explicit
sign-off):** "automatically enters an aggressive state" means the K9's
bite-and-hold/takedown actions become available with a single simplified
input (or with the target pre-selected) without navigating the radial menu
first, while the player still steers their own ped and presses the
confirming input themselves — this feature removes UI friction and does
target *selection* for the player, it does not remove player agency over
movement or the final action trigger. **If the other reading is actually
wanted** (a literal, automatic AI-driven attack requiring zero player
input), that is a fundamentally different and much larger build — a real
"AI takeover" mode this codebase has never attempted and explicitly
disclaims elsewhere — and needs its own dedicated sign-off and spec pass,
not a default assumption folded quietly into this one.

**Concrete behavior (under the recommended reading):**
- Trigger: the certified handler's (partnered per §12.0 item 4) health
  drops below `Config.Combat.HandlerDownDefense.handlerHealthThreshold`,
  detected server-side by **reusing Phase 2's already-built
  `server/tracking.lua` damage-event relay** rather than building a second
  ingestion path.
- "Nearest hostile": recommend defining this as "whoever the damage-event
  log already attributes as the source of the handler's most recent damage
  within `Config.Combat.HandlerDownDefense.hostileLookbackSeconds`" —
  reusing `CEventNetworkEntityDamage`'s attacker field, which Phase 2's
  blood-tracking relay already captures for a different purpose — rather
  than a generic "nearest other ped/player" scan, which would be far too
  broad (flags innocent bystanders) and has no native "hostility" concept
  to filter on otherwise.
- Partnership link: per §12.0 item 4, **recommended default (not
  decided):** require an **active leash pairing** at the moment of the
  health-drop event — the only "who is this K9's handler" link that
  currently exists in this codebase (`LeashPairs`), avoiding a whole new
  persistent "K9 partner" registry for Phase 3's first pass. Honestly
  flagged as a real functional limitation, not silently accepted as fine: a
  K9 deliberately off-leash during a foot chase — arguably the *more*
  common real scenario — would get no defense-mode support under this
  default.

**Reality check:** under the recommended non-AI-takeover reading, the
"aggressive state" itself is just a UI/targeting convenience layered on top
of BiteAndHold/NonLethalTakedown's already-assessed native feasibility — no
new native capability needed beyond what those two already require. Under
the alternative (AI-takeover) reading, this becomes a largely unscoped
scripted-combat-AI problem with no precedent anywhere in Phase 1/2 to build
on, and would need its own dedicated spec pass.

**Event/callback contract sketch:**
- No new client-triggerable *start* event — this is server-triggered off
  the existing damage-event log, mirroring §4.4's automatic-revoke path's
  "no client-reachable entry point at all" shape.
- `qbx_k9unit:client:handlerDownDefenseTriggered` (hostileNetId: number)
  [server→client, sent only to the partner K9's client] — presents the
  simplified-target prompt described above; applies no state by itself.
- The K9 player's own subsequent action still goes through the normal
  `requestBiteHold`/`requestTakedown` server callbacks and their normal
  validation (§12.5.1/§12.5.2) — this feature only pre-fills the target, it
  never creates a privileged action path that skips those checks.

**Open questions (blocking):**
- §12.0 item 4 (partnership link) is the central blocking question for
  this feature specifically — everything else here is downstream of it.
- The "UI convenience, not AI takeover" reading needs explicit sign-off
  given the direct tension with `SPEC.md` §2's standing non-goal — this is
  the single clearest place in Phase 3 where a literal reading of
  `SPEC.md`'s existing text would violate the project's own
  already-established non-goal, so it needs a real decision, not a silent
  pick either way.
- `handlerHealthThreshold`'s relationship to whatever downed/laststand
  system the target server actually runs (if raw health alone doesn't
  capture "downed" on a server using a separate incapacitation state — see
  PropDragging's identical dependency below) is unresolved.

### 12.5.4 Prop dragging (`Config.Features.PropDragging`)

**Concrete behavior:**
- Trigger: the K9 selects "Drag" from the radial on a nearby target within
  `Config.Combat.PropDragging.range` that is currently "downed."
- **"Downed" has no native definition and is an external integration
  dependency, not a design choice this document can make.** For an NPC
  ped, "downed" can be approximated natively (`IsPedDeadOrDying`, or a
  ragdolled-and-not-recovering state after a takedown). For a **player**
  target, "downed" almost always means a scripted incapacitation/laststand
  state owned by a *separate* resource on the target server (an EMS/
  ambulance job's laststand system, most commonly) — there is no generic
  native for this, the exact same shape of problem `SPEC.md` §11.6 already
  documented for door-lock state (*"door lock state... lives entirely
  inside a separate, server-specific... resource's own data model, with no
  vanilla native surface at all to query it from outside that resource"*).
  This resource cannot assume a specific laststand resource exists on any
  given server — PropDragging against a player target needs an explicit,
  documented integration point (an export/event this resource calls to ask
  "is this player downed," implemented by whoever runs the target server)
  rather than a guessed direct dependency, mirroring this resource's own
  precedent for bodycam integration (`SPEC.md` §2: *"Exports/events will be
  exposed so such integration is possible, but no particular external
  resource is assumed to exist"*).
- Effect (once a target is confirmed downed): the K9 attaches near a
  collar/scruff point and moves at `Config.Combat.PropDragging.dragSpeedMultiplier`
  of normal speed toward wherever the K9 player walks, up to
  `Config.Combat.PropDragging.maxDragDistance` before an automatic release
  — a safety cap **distinct from, do not conflate with,**
  `Config.LeashMaxDistance`. Either the K9 or the dragged player (if in
  scope) can end the drag at will, mirroring the leash's "no consent needed
  to get free" hard rule, even though *getting into* the drag needed no
  consent either (a downed target is, by construction, not in a position to
  consent either way).
- **NPC target:** straightforward `AttachEntityToEntity` on an NPC ped this
  client already has (or can request) network control of — no new
  architecture needed beyond what Phase 1's vehicle-load feature already
  uses safely.
- **Player target:** needs the same client-relay architecture as
  bite-and-hold's player-target case (§12.0 item 1) — the dragged player's
  own client must be the one to call `AttachEntityToEntity(myPed, k9Entity,
  ...)` on itself in response to a server-relayed instruction, for the
  identical "a client can only reliably control its own ped" reason the
  leash mechanic already documents. **If player targets are in scope,
  PropDragging is structurally closer to a hostile reskin of the leash
  mechanic than to a simple prop-attach** — worth naming explicitly since
  it is not obvious from `SPEC.md`'s one-line description.

**Reality check:** NPC-target dragging is fully native-only, no new asset
(same `AttachEntityToEntity` primitive Phase 1's vehicle-load feature
already uses). Player-target dragging is native-only from a pure-scripting
standpoint but carries the "downed" external-integration dependency above,
plus the same non-closable "target's client must cooperate" limitation as
bite-and-hold.

**Event/callback contract sketch:**
- `qbx_k9unit:server:requestDrag` (targetNetId: number) [client→server] —
  re-validates feature flag, access, live proximity, target type/scope, and
  the "is downed" check (native for NPC; via the external export for a
  player — **this document deliberately does not invent that export's
  name/signature**, matching this resource's own established pattern of
  flagging an unconfirmed integration rather than guessing one, per
  `SPEC.md` §9 items 11/12's precedent). Opens an ephemeral drag-state
  entry (K9 source ↔ target netId ↔ anchor point) — close enough in shape
  to `LeashPairs` that reusing/adapting that structure is worth considering
  at implementation time rather than inventing a third parallel shape.
- `qbx_k9unit:server:releaseDrag` () [client→server] — either party ends
  it, zero consent needed either direction, consistent with the leash's own
  hard "never trap someone with no self-service exit" rule, even though
  entry itself needed no consent.
- Distance/expiry safety valve mirroring the leash's hard-cap auto-detach,
  using `maxDragDistance` instead of `LeashMaxDistance`.

**Open questions (blocking):**
- §12.0 item 1 (PvP scope) again — this feature's cost differs the *most*
  across the NPC/player fork of any Phase 3 feature, since a player-target
  drag is nearly a whole second leash-shaped subsystem, not a small
  addition.
- **The "downed" integration point is a hard external dependency with no
  default answer** — cannot be resolved without knowing what downed/
  laststand resource (if any) the target server runs; exactly the kind of
  "depends on server-specific... asset availability you can't verify" this
  task's own instructions call out as a legitimate reason to block rather
  than guess.
- Should a drag-in-progress block the dragged player's own client-side
  interactions (chat, phone, etc.) or only movement? Not addressed —
  likely inherits whatever the host server's own "downed" state already
  does, but flagged since it isn't obviously implied either way.

### 12.5.5 Advanced agility — fence/window vault approximation (`Config.Features.AgilityAdvanced`)

**Concrete behavior:**
- Extends `client/movement.lua`'s existing `AgilityBasicJump` precedent
  (same file, same "self, own body" category) rather than a new file.
- When enabled and the K9 player is moving toward a detected low obstacle
  within `Config.Combat.AgilityAdvanced.maxVaultHeight`, a manual
  radial/keypress trigger fires a native jump task plus a scripted "vault"
  (a short forced-arc reposition of the ped over the obstacle — not a real
  climbing animation, unchanged from `SPEC.md` §7's existing framing),
  subject to `Config.Combat.AgilityAdvanced.vaultCooldownMs`.
- **Obstacle detection is a genuine, unresolved design fork** `SPEC.md` §7
  does not settle — it says the approximation is "similar to how existing
  parkour scripts approximate climbing for non-human peds" but not *how*
  the obstacle is actually detected:
  - **(a) Raycast/shape-test height detection**
    (`detectionMethod = 'raycast'`): fire a forward+upward shape-test ray
    from the K9's position, measure the height of whatever it hits, treat
    anything under `maxVaultHeight` as vaultable — generically, anywhere on
    the map, with zero per-fence config. Fully native/scriptable
    (`StartShapeTestCapsule`/`GetShapeTestResult` are ordinary,
    well-established natives), but carries real false-positive/negative
    risk against irregular world geometry (a ray clipping a fence post vs.
    a gap between slats, a low wall vs. a curb) that needs real in-engine
    tuning this document cannot do sight-unseen.
  - **(b) Explicit tagged-prop/zone whitelist**
    (`detectionMethod = 'taggedProp'`): a server owner adds specific
    fence/window prop models or world-coordinate zones to a new config
    table; vaulting only triggers near a listed entry. Safer/more
    predictable, and fully consistent with this codebase's existing
    config-driven philosophy (`Config.Peds`, `Config.K9Vehicles`, etc. all
    work this way), but imposes real, ongoing per-server setup burden (tag
    every fence you want climbable) none of Phase 3's other four features
    require.
  - **Not resolved here** — (a) and (b) produce visibly different config
    schemas and meaningfully different tuning/setup cost, and neither can
    be judged better without either live in-engine testing (for (a)'s
    false-positive rate) or a product decision about acceptable
    server-owner setup burden (for (b)).

**Reality check:** unchanged from `SPEC.md` §7's existing conclusion —
native jump/scripted-arc approximation only, no real climbing animation
("a real climbing animation blended to arbitrary fence heights would need a
custom clip set; not attempted here"). This document adds the
detection-method fork above, which §7 did not spell out.

**Event/callback contract sketch:** Minimal — almost entirely client-local
(own-body movement, same category as `AgilityBasicJump`), following the
existing pattern of no server round-trip for the K9's own locomotion. One
thing worth flagging: if vaulting is ever used to reach an area a player
normally couldn't (e.g., over a fence gating a restricted zone), a purely
client-side "did I vault" trust model means a modified client could claim
to have vaulted (or simply teleport) regardless — but this is no different
in kind from the already-accepted trust model for ordinary
jumping/movement everywhere else in GTA/FiveM (position is client-
authoritative for any normal ped movement baseline), so it is **not**
treated as a new gap requiring a server check here, consistent with how
Phase 1 already treats native locomotion as ungated. Flagged for
coder-security to confirm this reasoning holds, not asserted as certainly
fine.

**Open questions (blocking):**
- Detection method (a) vs. (b) above — a genuine, unresolved fork.
- Exact vault natives/animation for a quadruped skeleton — not verified
  this session (same caveat class as bite-and-hold's anim question).

---

## 12.6 — Cross-cutting notes carried forward from `SPEC.md` §9

- **§9 item 5 (PvP-balance review)** applies to every numeric value in
  §12.2's `Config.Combat` table — none of it is ready to default-enable
  without that review, and per this document's own findings the review
  scope is now larger than "cooldown tuning" alone: it should also cover
  §12.0 item 3 (target-eligibility restriction).
- Recommend looping in **config-validator** specifically on
  `Config.Combat`'s numeric knobs before Phase 3 implementation starts —
  this document's author flags the need rather than performing that review
  itself, consistent with this project's existing division of labor
  between spec-writing and balance/config review (the same posture
  `SPEC.md` §9 items 4/13 already took for Phase 2/4's placeholder
  numbers).
- Recommend a dedicated **coder-security** pass on §12.0's PvP-scope
  decision specifically — this is a bigger trust-boundary decision than any
  single Phase 1/2 item, closer in kind to the leash mechanic's own
  "resolved by explicit confirmation" moment (`SPEC.md` §9 item 3b) than to
  a routine feature-flag review.

## 12.7 — Quick-reference: decisions that must be made before implementation starts

1. PvP vs. PvE target scope (§12.0 item 1) — blocks BiteAndHold,
   NonLethalTakedown, PropDragging, and HandlerDownDefense's target
   selection.
2. Confirm the no-consent posture for hostile actions is intentional
   (§12.0 item 2), not an oversight relative to the leash precedent.
3. Target-eligibility restriction — can a same-department officer be a
   valid target? (§12.0 item 3.)
4. Handler-partnership link: reuse active leash pairing, or a new
   persistent registry? (§12.0 item 4.)
5. HandlerDownDefense's "aggressive state" reading — UI convenience
   (recommended) vs. literal AI takeover (conflicts with `SPEC.md` §2's
   standing non-goal) — §12.5.3.
6. PropDragging's "is this player downed" integration point — cannot be
   answered without knowing the target server's actual laststand/EMS
   resource — §12.5.4.
7. AgilityAdvanced's obstacle-detection method — raycast vs. tagged-prop
   whitelist — §12.5.5.
8. Native/animation verification passes not attempted this session: the
   bite/attack anim (§12.5.1), the fall-damage-suppression flag
   (§12.5.2), and the vault animation for a quadruped skeleton (§12.5.5).
9. `Config.Combat`'s numeric placeholders need a PvP-balance/
   config-validator pass before any flag in this phase defaults to `true`
   (§12.6).
