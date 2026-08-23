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

**Revision 2 (fork-resolution pass): product-agent, 2026-08-23,
jlwood17190665@gmail.com.** §12.0's four flagged design forks are
re-examined against two research passes that landed after the first draft
of this document — `phase2_notes/phase3_combat_patterns.md`
(community/ecosystem-pattern research) and `phase2_notes/phase3_combat_natives.md`
(native-verification research). Three of the four forks (PvP/PvE scope,
HandlerDownDefense's "aggressive state" reading, AgilityAdvanced's
obstacle-detection method) are now **decided** for Phase 3 on the strength
of that evidence; the fourth (PropDragging's "is this player downed"
dependency) is **narrowed** from an open unknown to a concrete, actionable
per-server integration requirement, made moot for Phase 3's *initial* ship
by the PvP/PvE resolution but still worth documenting for a possible future
phase. §12.0 is rewritten below to show exactly what's settled vs. still
genuinely open, and §12.1–§12.7 are updated wherever they referenced the
now-resolved items. No `.lua` file was touched to produce this revision
either — still planning only.

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
contracts materially depending on the answer. Three of the four originally
flagged there are now decided (§12.0 items 1–3 below); the fourth is
narrowed to a non-blocking, concrete per-server task (§12.0 item 4); three
further items carried over from the first draft remain genuinely open
(§12.0 items 5–7). **No `Config.Features` flag in this phase should be
flipped to `true` on a live server, and no implementation should start past
a design-review pass, until:**
- **items 5–7 are answered** by a human decision-maker or an explicitly
  delegated specialist (coder-security / config-validator, per §12.6), and
- **items 1–3's decisions get an explicit human sign-off** — they are
  settled defaults for this document, not yet a green light, because item
  1 is a visible scope reduction from `SPEC.md` §6.2's literal wording and
  item 3 still needs in-engine false-positive/negative tuning before its
  numeric thresholds are trustworthy, even though the *method* itself is
  no longer in question.

---

## 12.0 — Cross-cutting design forks: resolved and open (read this first)

### RESOLVED — settled defaults for Phase 3, pending the sign-off noted above

#### 1. PvP vs. PvE target scope — DECIDED: NPC (AI ped) targets only for Phase 3

**Decision:** all four target-taking mechanics (`BiteAndHold`,
`NonLethalTakedown`, `PropDragging`, and `HandlerDownDefense`'s target
selection) ship in Phase 3 scoped to **NPC (AI-controlled ped) targets
only.** Player-vs-player K9 combat is **out of scope for Phase 3**, not a
deprioritized "do it later this phase" item — it is a distinct, separately-
scoped extension that would need its own dedicated security review if this
project ever revisits it in a future phase.

This was originally written as "a recommendation, not a decision," pending
sign-off on the functionality reduction from `SPEC.md` §6.2's literal
wording ("target ped/player," "nearest hostile"). `phase2_notes/phase3_combat_patterns.md`
resolves that sign-off question by removing the main reason to hesitate —
choosing NPC-only isn't just architecturally cheaper, it is also the
**only** version of this feature set with any real ecosystem precedent
behind it:

- **v-k9** is the one surveyed script that actually shares this codebase's
  architecture — a player plays the K9 directly, not a handler commanding a
  spawned NPC dog. It has **no bite/attack/takedown/drag mechanic of any
  kind.** The one architectural cousin to this codebase in the wild has
  never attempted the problem player-target combat would be solving here.
- Every other surveyed script with an actual bite/attack or auto-defend
  mechanic (empfi/QB-K9's attack-queue system, ND-K9's on-command attack,
  the "AI Guards"/bodyguard family for auto-defend) achieves it by
  commanding an **NPC** the resource already has full network authority
  over. None of them relay a hostile effect onto a live player's own client
  and rely on that client to cooperate — the pattern this document's own
  architectural analysis already flagged as the only correct approach for a
  player target, and its "a modified client can simply ignore the
  instruction" limitation, has **no shipped analog anywhere in this
  survey** to point to as reassurance that it's low-risk.
- Net effect: NPC-only is not a compromise reached for lack of a
  decision-maker. It is both the cheaper build **and** the one backed by
  actual precedent, while the player-target case is confirmed genuine,
  unprecedented ground for this specific "player plays the dog" niche.

**What this changes concretely, applied throughout §12.5 below:**
- `SPEC.md` §6.2's wording is deliberately narrowed for Phase 3's
  implementation to "target NPC ped" — still worth a one-line human
  sign-off before implementation starts, since it is a visible reduction
  from the literal one-line feature description, but no longer a blocking
  fork that needs its own resolution before a decision can even be made.
- Player-vs-player K9 combat becomes an explicit **Phase 3 non-goal**
  (fold into `SPEC.md` §2's non-goals list whenever this document is
  folded in) — a possible future phase, scoped and reviewed separately,
  never a silent variant of the same feature.
- Items 5 and 6 below (both originally scoped around live-player targets:
  non-consensual state application, same-department target eligibility)
  are downstream consequences of this decision — see their entries below.
- Every "only if player targets are in scope" branch in §12.5's per-feature
  text is now **out of scope for Phase 3's implementation**, retained only
  as forward-looking design notes for a possible future PvP phase, not as
  work to schedule now.

#### 2. HandlerDownDefense's "aggressive state" — DECIDED: UI/auto-targeting convenience, not AI takeover

**Decision:** `SPEC.md` §6.2's "the K9 automatically enters an aggressive
state ... with no manual radial input required" means the K9's
bite-and-hold/takedown actions become available through a single
simplified, pre-targeted input instead of navigating the radial menu first
— the K9 player still steers their own ped and still presses the
confirming input themselves. This is the **settled interpretation** for
Phase 3, not a recommendation awaiting sign-off. The literal alternative
reading (a fully autonomous, zero-input AI attack) is **rejected** for this
feature: it would require this resource to take control of the K9 player's
own ped, which directly conflicts with `SPEC.md` §2's own standing,
explicit non-goal ("this resource never spawns, possesses, or
remote-controls a K9 ped on anyone's behalf") and with §1's "The K9 player
controls themselves directly, like any other player character, at all
times." A resource cannot simultaneously hold that non-goal and ship a
feature that violates it — one of the two readings has to give, and it
isn't the standing non-goal.

`phase2_notes/phase3_combat_patterns.md` supplies the evidence that makes
this a decision rather than a guess: the closest ecosystem analog to
"something auto-defends a player" is the standalone bodyguard/guard-NPC
family ("Advanced AI Bodyguards," "AI Guards," etc.), and **every one of
them works only because the defending entity is an NPC** the resource
already commands directly via `TaskCombatPed`-class natives. No ecosystem
precedent was found for a *player-controlled* companion automatically
fighting on the player's behalf without either (a) the companion actually
being an NPC, or (b) a literal, disclosed AI takeover of that player's
inputs. Since (a) doesn't apply here (the K9 is a real player's own
character, not an NPC this resource owns) and (b) is the already-rejected
reading, the UI-convenience reading is the **only** version of this
feature with any real precedent for a player-controlled entity — the
ecosystem's silence on the alternative is itself confirmation, not just an
absence of counter-evidence.

**Acceptance criteria, made unambiguous (supersedes the "recommended
reading, not decided" framing in the original §12.5.3):**
- [ ] A HandlerDownDefense trigger **never**, by itself, moves the K9's
      ped, fires a weapon, plays a combat animation, or applies any task/
      control to the K9 player's own character. Its only effect is
      presenting a prompt and/or pre-selecting a target.
- [ ] The K9 player must still manually confirm (press the simplified
      input / confirm the prompt) before any bite-and-hold or takedown
      action actually executes — the trigger event alone never causes an
      action to fire.
- [ ] The K9 player retains full manual control of their own ped's
      movement and camera at all times before, during, and after a
      HandlerDownDefense trigger — no `SetEntityCoords`,
      `TaskCombatPed`-class native, or control-input override is ever
      applied to the K9 player's own ped by this feature.
- [ ] Once confirmed, the action goes through the exact same
      `requestBiteHold`/`requestTakedown` server validation path as a
      manually-radial-triggered action (§12.5.1/§12.5.2) — this feature
      only pre-fills a target, it never opens a privileged action path
      that skips those checks.
- [ ] If a literal AI-takeover version of this feature is ever wanted, it
      is treated as a new, separately-scoped feature requiring its own
      `SPEC.md` §2 non-goal change and dedicated security review — not an
      alternate configuration of `HandlerDownDefense`.

#### 3. AgilityAdvanced obstacle detection — DECIDED: capsule-sweep raycast (`detectionMethod = 'raycast'`) as the Phase 3 default

**Decision:** `AgilityAdvanced` ships with `Config.Combat.AgilityAdvanced.detectionMethod
= 'raycast'` as the Phase 3 default, implemented as a **multi-height
capsule sweep** (`StartShapeTestCapsule`/`GetShapeTestResult`, confirmed
real natives per `phase2_notes/phase3_combat_natives.md` §5), not a single
forward ray. The tagged-prop/zone-whitelist option (`'taggedProp'`) is not
chosen as the default — it remains available in the config schema as a
possible per-server override for admins who want a stricter allowlist, but
it is not required and not the shipped behavior.

This decision follows directly from this resource's own established
standard elsewhere in the codebase: `client/main.lua`'s door-interaction
logic and the leash mechanic both prioritize a genuine, real check over a
convenient approximation — this codebase does not ship a safety/validity
check that fakes real validation when a real one is available and
buildable. `phase2_notes/phase3_combat_patterns.md` gives a concrete,
source-confirmed reason not to take the cheaper "just play the animation"
shortcut here: `Bonzaii99/bonz_parkour`, a real shipped FiveM parkour
script, has **zero obstacle detection** on its vault/flip moves — every
move fires unconditionally on a keybind regardless of what (if anything) is
actually in front of the player, letting a player "vault" into open air or
through a wall. That is a real, source-read example of exactly the naive
pattern this resource's own standard rules out, not a hypothetical risk to
guard against — it settles the "keypress-only" option as unacceptable for
this codebase rather than a legitimate cheaper alternative.

The research also identifies a concrete refinement for the chosen method:
`invalid0190/dynamic-sit` (a different mechanic, same underlying "is there
a valid surface/obstacle here" problem) is documented as using multi-height
vertical sweeps with a thick capsule scan rather than a single ray,
specifically to avoid the false-positive/negative risk this document's
first draft already flagged (a ray clipping a fence post vs. a gap between
slats). `phase3_combat_natives.md` independently confirms
`StartShapeTestCapsule`/`GetShapeTestResult` are real, current natives
capable of exactly this shape test — so the decided approach is both
supported by this resource's own standard and concretely buildable today.

**What remains genuinely open (implementation-tuning, not a design fork
anymore):**
- The exact height bands, capsule radius, and forward distance for the
  multi-height sweep need real in-engine tuning against actual map
  geometry (fence posts, curbs, low walls) before `AgilityAdvanced`
  defaults to enabled — this is expected, ordinary tuning work, not a
  blocking unknown the way the method choice itself was.
- `GetShapeTestResult`'s async polling contract (call repeatedly until it
  returns 0 or 2, per `phase3_combat_natives.md` §5) needs to be respected
  in the implementation — a concrete detail for whoever builds this, not a
  design question.
- The quadruped vault/climb animation remains unverified (unchanged from
  the original draft) — a separate, still-open asset question, not part of
  this fork.

### NARROWED — no longer a blocking unknown, reframed as a concrete task

#### 4. PropDragging's "is this player downed" integration point

**This is no longer a blocking dependency for Phase 3's initial ship.**
Because item 1 above scopes Phase 3 to NPC targets only, `PropDragging`'s
"downed" check for Phase 3 is fully native and requires no external
integration at all: `IsPedDeadOrDying(ped, true)` (the `true` flag counts a
ped mid-melee-takedown as dying, a good fit for "just knocked down by
`NonLethalTakedown`," per `phase2_notes/phase3_combat_natives.md` §4)
combined with `IsPedRagdoll` covers the NPC case completely, with zero
dependency on any other resource.

The player-target "downed" question is deferred along with all other
player-target combat work per item 1 — but it is worth documenting now,
concretely, as a **per-server integration requirement** for whenever a
future PvP phase is scoped, rather than leaving it as an undifferentiated
"depends on the server" note:

- **What a server would need to provide:** a way for this resource to ask
  "is this specific player currently in a downed/incapacitated state,"
  answered by whatever EMS/laststand system that server actually runs.
  `phase2_notes/phase3_combat_patterns.md` confirms this is exactly how
  mature cuffing/laststand integrations already work in the QBCore/Qbox
  ecosystem in practice — most police/EMS resources expose this as **player
  metadata** (commonly shaped like `Player.PlayerData.metadata.isdead` /
  `.inlaststand` / a similarly-named laststand flag, per widely-used
  QBCore/Qbox metadata conventions), not a bespoke export — though this is
  offered as the *plausible shape* of the integration, not a confirmed
  export name/signature for any specific resource.
- **The concrete integration point this document commits to, for whenever
  it's needed:** a two-part contract, matching this resource's own existing
  precedent for bodycam/other integrations (`SPEC.md` §2: "exports/events
  will be exposed so such integration is possible, but no particular
  external resource is assumed to exist") —
  1. A default check against the common Qbox/QBCore metadata convention
     above (read `metadata.isdead`/`.inlaststand` if the player's data
     structure exposes it), used automatically with no server-side setup
     for the common case.
  2. An explicit override hook (a `Config.Combat.PropDragging.IsPlayerDownedOverride`
     function slot in `config.lua`, following the same "server owner fills
     in a config function" pattern already used elsewhere in this
     ecosystem for bridge-style integrations) for any server running a
     non-standard EMS/laststand system whose downed state isn't reachable
     through the default metadata check.
- This reframes the item from "cannot be resolved without knowing the
  target server's resource" to "resolved architecture, pending only the
  actual implementation once player-target dragging is ever in scope" — a
  concrete task for a coder to pick up in a future phase, not an open
  question blocking anything in Phase 3.

### STILL OPEN — not addressed by this evidence pass, genuinely unresolved

#### 5. Non-consensual state application posture (was item 2 in the original draft)

Now **dormant, not resolved**, as a direct consequence of item 1: Phase 3's
NPC-only scope means no hostile, non-consensual state is ever applied to a
*real player's own character* in this phase — an NPC has no consent to
give or withhold in the way this codebase's leash-consent precedent cares
about, so the "deliberate reversal of the leash precedent" tension the
original draft flagged doesn't actually arise for anything shipping in
Phase 3. This item **returns** the moment a future PvP phase is ever
scoped, and should be re-raised explicitly at that time — it is not
answered here, only rendered inapplicable for now.

#### 6. Target-eligibility restriction — same-department griefing (was item 3)

Also **dormant**, for the identical reason: this only matters once a real
officer-player can be a bite/takedown/drag *target*, which item 1 rules out
for Phase 3. Re-raise if a future PvP phase is scoped; no new evidence
bears on the underlying question either way.

#### 7. Handler-partnership link: reuse active leash pairing, or a new persistent registry? (was item 4)

**Genuinely unresolved — this evidence pass provides nothing that bears on
this question, and this document does not force an answer it can't
support.** Neither `phase2_notes/phase3_combat_patterns.md` nor
`phase2_notes/phase3_combat_natives.md` researched or surfaced anything
about how other K9/handler-pair scripts model an ongoing partnership link
independent of a leash-equivalent mechanic (the surveyed scripts are
overwhelmingly handler-commands-NPC-dog architectures where "who's the
handler" is trivial and definitionally always true, not a relationship that
needs its own persistence model the way a player-plays-the-dog design
does). Resolving this still needs one of: (a) an explicit product decision
that reusing the leash pairing's real functional limitation (no defense
support for an off-leash K9 mid-chase) is an acceptable Phase 3 trade-off,
or (b) a scoped design pass for a new "K9 partnership" registry, neither of
which this document can respons­ibly pick from the evidence available. The
original draft's two options (§12.5.3's "(a) reuse active leash pairing" /
"(b) new persistent registry") stand unchanged, still with (a) as the
lower-cost **default-if-forced**, but not elevated to a decision here.

---

## 12.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| **3a — independent, start immediately** | `AgilityAdvanced` | Pure client-local own-body movement (extends `client/movement.lua`'s existing `AgilityBasicJump` precedent) — does not touch target/combat logic. Detection method is now decided (§12.0 item 3: capsule-sweep raycast) — the remaining work is in-engine tuning, not a design fork, so this is an even cleaner first ticket than in the original draft. |
| **3b — foundational, blocked on §12.0 item 7** | `BiteAndHold` | Establishes the target-effect pattern for NPC targets (§12.0 item 1 is now decided: NPC-only, so this is the simpler direct-entity-command path, not the player-relay-and-cooperate one) and the shared hold/incapacitate ephemeral state + Recall actor (§12.0 item 7) every later combat feature either reuses or mirrors. Item 7 (handler-partnership link) is the one remaining blocker for this sub-phase. |
| **3c — depends on 3b's target infra** | `NonLethalTakedown` | Reuses whatever target-effect shape 3b establishes; additionally needs new "recent speed history per targetable entity" server state not built by anything else in this codebase yet (§12.5.2). |
| **3d — depends on 3b/3c's target infra** | `PropDragging` | **No longer blocked on an external integration decision** — §12.0 item 4 confirms Phase 3's NPC-only scope makes the "downed" check fully native (`IsPedDeadOrDying`/`IsPedRagdoll`), with zero dependency on any other resource. The documented metadata-based integration point for a future player-target case is forward-looking design only, not a Phase 3 blocker. |
| **3e — depends on Phase 2's tracking infra AND §12.0 item 7** | `HandlerDownDefense` | Reuses Phase 2's `server/tracking.lua` damage-event log rather than building a second one, and is a pure consumer of 3b/3c's own target-action paths (per §12.0 item 2's now-decided UI-convenience reading, it only pre-selects a target, it doesn't add a new privileged action or take control of the K9 player). Land last — it has no infra of its own to contribute, only to consume. Still blocked on item 7 (handler-partnership link) for the same reason as 3b. |

---

## 12.2 Config schema additions (sketch)

New top-level `Config.Combat` table, in the same style as existing blocks
(banner comments, inline rationale). **Every numeric value below is an
unreviewed placeholder** — flagged explicitly for a PvP-balance /
config-validator pass (`SPEC.md` §9 item 5, expanded by §12.6 below) before
any of this is wired to real code, exactly the same status Phase 2's
`Config.SearchContrabandItems` / `Config.ContrabandAlertTiers` shipped with.
(§12.0's fork resolutions affect which *keys* exist and their scope, not
whether these numbers are tuned — that review is still outstanding.)

```lua
-- ======================================================================
-- PHASE 3 — COMBAT & ADVANCED AGILITY. Every leaf feature independently
-- gated by its own Config.Features flag (already present as placeholders).
-- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
-- PvP-balance/config-validator pass (SPEC.md §9 item 5) -- do not treat any
-- of these as tuned, and do not default-enable the owning feature before
-- that review, per PHASE3_SPEC.md §12.0/§12.6.
-- Phase 3 scope note (PHASE3_SPEC.md §12.0 item 1, DECIDED): every target
-- below is an NPC ped. Player-vs-player targeting is out of scope for this
-- phase, not merely disabled by default.
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
        healthFloor      = 100,    -- backstop only, NOT the primary non-lethal mechanism -- primary mechanism is SetEntityCanBeDamaged bracketing, see §12.5.2
    },
    HandlerDownDefense = {
        handlerHealthThreshold  = 100, -- needs review against this server's real max-health/downed-system numbers, see §12.5.3
        triggerRadius           = 15.0, -- max distance from the handler for the partner K9 to receive the defense-mode prompt
        hostileLookbackSeconds  = 10,   -- "hostile" = whoever last damaged the handler within this window, reusing Phase 2's relayDamageEvent log
    },
    PropDragging = {
        range               = 2.0,
        dragSpeedMultiplier = 0.6,  -- via SET_PED_MOVE_RATE_OVERRIDE -- must be re-asserted every tick while dragging, this native is NOT a one-shot toggle, see §12.5.4
        maxDragDistance     = 30.0, -- safety-valve auto-release distance -- UNRELATED to Config.LeashMaxDistance, do not conflate
        -- IsPlayerDownedOverride: function(playerId) -> boolean, OPTIONAL.
        -- Forward-looking hook only, not needed for Phase 3's NPC-only scope
        -- -- see §12.0 item 4. Left commented out until a future PvP phase
        -- actually needs it, so it isn't mistaken for an active Phase 3 knob.
    },
    AgilityAdvanced = {
        detectionMethod = 'raycast', -- DECIDED (§12.0 item 3): multi-height capsule sweep via StartShapeTestCapsule/GetShapeTestResult. 'taggedProp' remains available as an optional per-server override, not the Phase 3 default.
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
| `client/combat.lua` | **New** | BiteAndHold + NonLethalTakedown self-initiated triggers (radial item, local anim, calls the server callbacks below), and now also PropDragging's client-side trigger (see the `client/dragging.lua` row below — folded in per §12.0 item 1's NPC-only resolution). Kept out of `client/movement.lua` for the same "don't let one file balloon" reasoning §11.3 already applied to `client/tracking.lua`/`client/search.lua`. |
| `server/combat.lua` | **New** | BiteAndHold + NonLethalTakedown server authority: re-validates access/range/target-scope/eligibility (NPC-ped only per §12.0 item 1), computes the server-side speed gate for takedown (§12.5.2 — genuinely new state, not present anywhere in this codebase yet), applies the health floor plus `SetEntityCanBeDamaged` bracketing, and owns the ephemeral "who's currently held/recalled" state (mirrors `LeashPairs`' shape/hygiene conventions in `server/main.lua` — disconnect cleanup, no unbounded growth). |
| `client/defense.lua` | **New** | HandlerDownDefense's client-side presentation **only** — per §12.0 item 2's now-decided reading, this never applies any state to or takes control of the K9 player's own ped; it only streamlines target selection into the existing `client/combat.lua` action paths, which still require the player's own confirming input. |
| `server/defense.lua` | **New** | Hooks into `server/tracking.lua`'s **existing** damage-event log (Phase 2) rather than building a second one; watches for a partnered handler's health crossing `Config.Combat.HandlerDownDefense.handlerHealthThreshold` and, if a partnership link resolves (§12.0 item 7 — still open), notifies the partner K9's client. |
| `client/dragging.lua` | **Folded into `client/combat.lua`, decided** | §12.0 item 1's NPC-only resolution makes this small enough to fold in, as the original draft's contingency already anticipated — no separate file needed for Phase 3. If a future PvP phase brings player targets into scope, this should be split back out at that time, mirroring `client/movement.lua`'s leash section, per the original draft's reasoning. |
| `client/movement.lua` | **Extends** | `AgilityAdvanced`'s vault trigger and multi-height capsule-sweep detection (§12.0 item 3) — same file, same "self, own body, native locomotion" category `AgilityBasicJump`'s existing suppression thread already lives in. |
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
  target (**NPC ped only, per §12.0 item 1, DECIDED** — not a scope
  recommendation anymore), passing `CanShowK9UI()`.
- Effect: the K9 plays a latch/bite animation oriented at the target
  (attached near the target's arm/torso per `SPEC.md` §7's existing
  framing — no rigid physical bone attachment); the target enters a "held"
  state lasting up to `Config.Combat.BiteAndHold.maxDurationMs`, ending
  early on (a) the K9 player selecting "Release," or (b) — once §12.0 item
  7 is resolved — a recognized partner handler issuing "Recall," whichever
  comes first.
- While held: the target's AI is suppressed via a forced anim/task-pause
  plus `SetBlockingOfNonTemporaryEvents`/`SetPedFleeAttributes` (both
  confirmed real natives, `phase2_notes/phase3_combat_natives.md` §1) so it
  neither flees nor attacks meaningfully; no lethal damage is applied by
  the hold itself (see the open question below on whether *any* damage
  applies).
- One hold at a time per K9; a new bite attempt on a target already held by
  someone else is rejected server-side (`already_held`), never silently
  double-applied.
- **Player-target bite-and-hold is out of scope for Phase 3** per §12.0
  item 1's decided resolution. The design text that previously described a
  player-target self-suppress path (target's own client relaying
  `DisableControlAction` on sprint/fire) is retained only as a forward
  design note for a possible future PvP phase — it is not scheduled work
  for this phase, and `DisableControlAction`'s established-in-this-codebase
  status (`client/movement.lua`'s `AgilityBasicJump`) means no new native
  verification would be needed if that phase is ever scoped.

**Reality check:** unchanged conclusion from `SPEC.md` §7 — task/animation
plus a control-disable/AI-suppression state, not a literal rigid-body bite.
**Anim status (narrowed, not closed, by `phase2_notes/phase3_combat_natives.md`
§1):** a real candidate clip was found —
`creatures@rottweiler@melee@streamed_core@` / `takedown_from_back` — but it
is a one-shot Rottweiler-specific takedown pose, not a sustained bite-hold
loop, at MEDIUM confidence (one-notch-removed source), and has no confirmed
equivalent for this resource's other configured breeds. This is not one of
the four forks this revision resolves — it remains an open
animation-asset question needing an in-engine preview before
implementation, exactly as `phase2_notes/phase3_combat_natives.md` §1
recommends.

**Event/callback contract sketch:**
- `qbx_k9unit:server:requestBiteHold` (targetNetId: number)
  [client→server, `server/combat.lua`] — re-validates
  `Config.Features.BiteAndHold`, `HasK9Access(source)`, live proximity to
  the resolved entity (never a client-claimed distance — same
  step-ordering discipline as `contraband_search_contract.md`'s step 8),
  that the entity isn't already held, and that the entity is a valid NPC
  ped (reject any player-controlled entity outright — §12.0 item 1 makes
  this a hard scope check, not a soft preference). On success: opens an
  ephemeral hold-state entry keyed by the K9's source (target netId/entity
  + expiry timestamp) and broadcasts a cosmetic "played anim" event to
  nearby clients.
- `qbx_k9unit:server:releaseBiteHold` () [client→server] — the holding K9
  (or, once §12.0 item 7 is resolved, the recognized partner handler) ends
  the hold early. Mirrors the leash's "ending it needs no consent, only
  starting it needed a check" shape.
- Server-side timeout past `maxDurationMs` auto-clears the hold the same
  way the leash's hard-cap safety valve auto-detaches — reuse that pattern
  (a periodic sweep or per-hold `SetTimeout`), never a client-trusted "my
  timer expired" claim.
- **Never client-authoritative:** whether a hold is active, when it
  started/expires, and whether the target is currently suppressed are all
  server state.

**Open questions (remaining, not blocked by any of the four resolved
forks):**
- Exact bite/attack anim in-engine quality (see above) — needs a preview
  pass, not a guess.
- Does a held target take any damage over the hold duration, or is it
  purely a control/mobility restriction with zero damage? `SPEC.md` §6.2's
  own wording ("interrupts the target's sprint/weapon-fire ability") reads
  as the latter — recommending that reading explicitly since it's simplest
  and matches the literal text, but flagging for a conscious sign-off
  rather than an unstated assumption.
- §12.0 item 7 (handler-partnership link, for the Recall actor) still
  applies and is still open.

### 12.5.2 Non-lethal takedown (`Config.Features.NonLethalTakedown`)

**Concrete behavior:**
- Trigger: same self-initiated radial pattern as bite-and-hold, requiring
  the target (an **NPC ped, per §12.0 item 1, DECIDED**) to currently be
  "fleeing" — defined as **server-computed speed over the last few position
  samples exceeding `Config.Combat.NonLethalTakedown.minTargetSpeed`**,
  explicitly **not** a client-reported "I am sprinting" claim. For an NPC
  target this is trivially computed server-side from consecutive
  `GetEntityCoords` polls (the server already has authoritative position
  for any networked entity).
- Effect: the K9 forces a ragdoll on the target via `SET_PED_TO_RAGDOLL_WITH_FALL`
  (the real native — `phase2_notes/phase3_combat_natives.md` §2 corrects
  the original draft's informal `TaskRagdollPed` name and recommends the
  directional-fall variant over the plain one); no weapon/melee damage is
  applied by the action itself. The primary non-lethal mechanism is now
  concretely resolved: bracket the forced ragdoll with
  `SetEntityCanBeDamaged(target, false)` immediately before the ragdoll
  task and `SetEntityCanBeDamaged(target, true)` on hold-end/timeout — this
  is a real, confirmed native (no dedicated fall-damage-only flag exists,
  per the natives pass) that blocks all damage sources during the window,
  not just fall damage, which is a more robust primary mechanism than the
  original draft's TBD placeholder. `Config.Combat.NonLethalTakedown.healthFloor`
  remains a secondary backstop, unchanged in role.

**Reality check:** fully native-only, zero new asset, no open native
questions remain for this feature — `phase2_notes/phase3_combat_natives.md`
§2 closes out both items the original draft flagged as unverified (the
ragdoll native's real name, and the fall-damage-suppression mechanism).
`SET_ENTITY_INVINCIBLE` was checked and explicitly **not** used, since its
documented side effect of suppressing ragdoll reactions on at least one
damage source would fight the very ragdoll this feature needs to look
convincing.

**Event/callback contract sketch:**
- `qbx_k9unit:server:requestTakedown` (targetNetId: number)
  [client→server, `server/combat.lua`] — re-validates feature flag, access,
  live proximity, that the target is an NPC ped (§12.0 item 1), **and** the
  server-computed speed gate (reject `not_fleeing` if recent speed samples
  don't clear `minTargetSpeed`). This is the one check in this whole
  document requiring the server to already track a short rolling position
  history per potentially-targetable entity — genuinely new state.
- Cooldown: per-K9 (`cooldownMs`) **and** per-target (`targetCooldownMs`) —
  the per-target cooldown exists specifically to stop repeat takedowns of
  the same already-downed target by multiple K9s in quick succession.
- Ordering: `SetEntityCanBeDamaged(target, false)` and the health floor
  apply **before** triggering `SetPedToRagdollWithFall`, and
  `SetEntityCanBeDamaged(target, true)` restores on release/timeout — the
  same ordering-matters discipline `contraband_search_contract.md`'s
  proximity-before-inventory-read step already established for this
  codebase, now paired with a concrete, confirmed native.

**Open questions (remaining):**
- The "rolling speed history per targetable entity" state is new
  infrastructure this document flags but does not design in detail.
- Should a takedown leave the target in a state some other resource's
  cuff/restraint system can pick up, or is it purely cosmetic? Recommend
  exposing an export/event hook rather than assuming a specific cuff
  resource exists — not decided here.
- §12.0 item 7 does not directly affect this feature (no Recall actor
  applies to a takedown), so nothing here is blocked by the still-open
  items.

### 12.5.3 Handler-down defense (`Config.Features.HandlerDownDefense`)

**Settled reading (was: "recommended, assumed, not decided" — see §12.0
item 2 above for the full resolution and evidence):** *"the K9
automatically enters an aggressive state ... with no manual radial input
required"* (`SPEC.md` §6.2) means the K9's bite-and-hold/takedown actions
become available via a single simplified, pre-targeted input, **not** that
this resource takes control of the K9 player's own ped. The literal
"automatic, zero-input AI attack" reading is rejected outright for this
feature — it would conflict with `SPEC.md` §2's standing non-goal and §1's
"the K9 player controls themselves directly ... at all times," and
`phase2_notes/phase3_combat_patterns.md`'s bodyguard/guard-NPC research
confirms no ecosystem precedent exists for that reading applied to a
*player-controlled* companion. See §12.0 item 2 for the full acceptance
criteria; they are the authoritative version of this feature's behavior and
are not repeated in full here to avoid drift between two copies of the same
checklist.

**Concrete behavior (under the settled reading):**
- Trigger: the certified handler's (partnered per §12.0 item 7 — still
  open) health drops below `Config.Combat.HandlerDownDefense.handlerHealthThreshold`,
  detected server-side by **reusing Phase 2's already-built
  `server/tracking.lua` damage-event relay** rather than building a second
  ingestion path.
- "Nearest hostile": recommend defining this as "whoever the damage-event
  log already attributes as the source of the handler's most recent damage
  within `Config.Combat.HandlerDownDefense.hostileLookbackSeconds`" —
  reusing `CEventNetworkEntityDamage`'s attacker field. Per §12.0 item 1's
  now-decided NPC-only scope, if the attributed hostile is itself a player
  rather than an NPC, the pre-selected target must be rejected/ignored by
  the downstream `requestBiteHold`/`requestTakedown` validation exactly the
  same way any other player-target attempt is — this feature does not get
  a special exemption from the NPC-only scope just because the target was
  auto-selected rather than manually chosen.
- Partnership link: per §12.0 item 7 (still open), **default-if-forced:**
  require an active leash pairing at the moment of the health-drop event —
  the only "who is this K9's handler" link that currently exists in this
  codebase (`LeashPairs`). Honestly flagged as a real functional
  limitation: a K9 deliberately off-leash during a foot chase gets no
  defense-mode support under this default.

**Reality check:** confirmed by `phase2_notes/phase3_combat_natives.md`
§3 — under the settled reading, this feature needs no new native
capability beyond what BiteAndHold/NonLethalTakedown already require; it
is purely a server-triggered UI/targeting convenience. `TASK_COMBAT_PED`
(the native an AI-takeover version would need) is confirmed to exist but
is explicitly not used here, since that reading is rejected.

**Event/callback contract sketch:**
- No new client-triggerable *start* event — this is server-triggered off
  the existing damage-event log.
- `qbx_k9unit:client:handlerDownDefenseTriggered` (hostileNetId: number)
  [server→client, sent only to the partner K9's client] — presents the
  simplified-target prompt described above; applies no state by itself.
- The K9 player's own subsequent action still goes through the normal
  `requestBiteHold`/`requestTakedown` server callbacks and their normal
  validation (§12.5.1/§12.5.2), including the NPC-only scope check.

**Open questions (remaining):**
- §12.0 item 7 (partnership link) is the one still-open blocking question
  for this feature specifically.
- `handlerHealthThreshold`'s relationship to whatever downed/laststand
  system the target server actually runs is unresolved — but no longer a
  hard blocker the way PropDragging's equivalent question was, since this
  feature's own trigger is the handler's raw health crossing a threshold,
  not a "is this player downed" query to an external system. Worth a
  config-validator pass, not a design fork.

### 12.5.4 Prop dragging (`Config.Features.PropDragging`)

**Concrete behavior:**
- Trigger: the K9 selects "Drag" from the radial on a nearby **NPC** target
  (per §12.0 item 1, DECIDED) within `Config.Combat.PropDragging.range`
  that is currently "downed."
- **"Downed," for Phase 3's NPC-only scope, is fully resolved and fully
  native:** `IsPedDeadOrDying(ped, true)` — the `true` argument counts a
  ped mid-melee-takedown as dying even before its death task starts, a
  good fit for "just knocked down by `NonLethalTakedown`" — combined with
  `IsPedRagdoll` for "still ragdolled and not recovering." No external
  integration dependency applies to Phase 3's shipped scope at all. (See
  §12.0 item 4 above for the full resolution of the player-target case,
  narrowed to a concrete, non-blocking forward design note rather than an
  open unknown.)
- Effect (once a target is confirmed downed): the K9 attaches near a
  collar/scruff point (`AttachEntityToEntity`, already used safely in this
  exact codebase for `client/vehicle.lua`'s vehicle load-in) and moves at
  `Config.Combat.PropDragging.dragSpeedMultiplier` of normal speed via
  `SET_PED_MOVE_RATE_OVERRIDE`, up to `Config.Combat.PropDragging.maxDragDistance`
  before an automatic release — a safety cap **distinct from, do not
  conflate with,** `Config.LeashMaxDistance`. **Implementation note surfaced
  by `phase2_notes/phase3_combat_natives.md` §4:** `SET_PED_MOVE_RATE_OVERRIDE`
  is documented as needing to be looped/re-asserted every tick the drag is
  active — it is not a one-shot toggle the way some other override natives
  in this codebase are, so implementation must not call it once at
  drag-start and assume it persists.
- Either the K9 or (in a future PvP phase, if ever scoped) the dragged
  player can end the drag at will, mirroring the leash's "no consent needed
  to get free" hard rule.

**Reality check:** NPC-target dragging is fully native-only, zero new
asset, and now has **zero open questions** for Phase 3's scope — both
previously-flagged unknowns (the exact "downed" check, and the drag-speed
native's persistence behavior) are resolved by
`phase2_notes/phase3_combat_natives.md` §4.

**Event/callback contract sketch:**
- `qbx_k9unit:server:requestDrag` (targetNetId: number) [client→server] —
  re-validates feature flag, access, live proximity, that the target is an
  NPC ped (§12.0 item 1), and the native "is downed" check above. Opens an
  ephemeral drag-state entry (K9 source ↔ target netId ↔ anchor point) —
  close enough in shape to `LeashPairs` that reusing/adapting that
  structure is worth considering at implementation time.
- `qbx_k9unit:server:releaseDrag` () [client→server] — either party ends
  it, zero consent needed either direction.
- Distance/expiry safety valve mirroring the leash's hard-cap auto-detach,
  using `maxDragDistance` instead of `LeashMaxDistance`.

**Open questions (remaining):**
- None blocking for Phase 3's NPC-only scope.
- Forward-looking only (not Phase 3 work): if a future PvP phase brings
  player-target dragging into scope, implement the two-part "downed"
  integration contract specified in §12.0 item 4 above (default
  metadata-convention check + `IsPlayerDownedOverride` config hook) before
  building that phase's dragging path.

### 12.5.5 Advanced agility — fence/window vault approximation (`Config.Features.AgilityAdvanced`)

**Concrete behavior:**
- Extends `client/movement.lua`'s existing `AgilityBasicJump` precedent
  (same file, same "self, own body" category) rather than a new file.
- When enabled and the K9 player is moving toward a detected low obstacle
  within `Config.Combat.AgilityAdvanced.maxVaultHeight`, a manual
  radial/keypress trigger fires a scripted "vault" (a short forced-arc
  reposition of the ped over the obstacle via `SetEntityVelocity`,
  optionally layered with `TaskPlayAnim` for a jump-adjacent pose — not a
  real climbing animation, unchanged from `SPEC.md` §7's existing framing),
  subject to `Config.Combat.AgilityAdvanced.vaultCooldownMs`.
- **Obstacle detection — DECIDED, see §12.0 item 3:** a multi-height
  capsule sweep (`StartShapeTestCapsule`/`GetShapeTestResult`, both
  confirmed real, current natives) fired forward+upward from the K9's
  position, measuring the height of whatever it hits across several height
  bands rather than a single ray, treating anything under `maxVaultHeight`
  as vaultable. This is the Phase 3 default (`detectionMethod = 'raycast'`
  in §12.2's config sketch). The tagged-prop/zone whitelist option remains
  available as an optional per-server override in the config schema for
  admins who want a stricter, curated allowlist, but it is not the shipped
  default and does not need to be built for Phase 3's initial ship.
- **Wording correction from `phase2_notes/phase3_combat_natives.md` §5:**
  there is no generic ped "jump task" native — jump is native-locomotion/
  input-driven (`INPUT_JUMP`, already used by `AgilityBasicJump`), not a
  scriptable task the way `TaskCombatPed`/`TaskPlayAnim` are. The actual
  implementation path is either layering the scripted arc on top of the
  ped's own native jump input, or driving the whole arc via
  `SetEntityVelocity`/`SetEntityCoords` directly from the radial/keypress
  trigger — either is native-only and buildable; this is a precision fix
  to the original draft's phrasing, not a feasibility change.

**Reality check:** unchanged from `SPEC.md` §7's existing conclusion for
the animation side — native-only mechanical approximation, no real
climbing animation exists or is expected to exist as a reusable vanilla
asset. The detection-method fork is now closed (§12.0 item 3); what
remains is ordinary in-engine tuning of the sweep's height bands/radius,
not a design question.

**Event/callback contract sketch:** Minimal — almost entirely client-local
(own-body movement, same category as `AgilityBasicJump`), following the
existing pattern of no server round-trip for the K9's own locomotion. The
original draft's trust-model note stands unchanged: a purely client-side
"did I vault" model is not treated as a new gap requiring a server check,
consistent with how Phase 1 already treats native locomotion as ungated —
flagged for coder-security to confirm this reasoning holds, not asserted
as certainly fine.

**Open questions (remaining, tuning/asset-level, not design forks):**
- In-engine tuning of the multi-height sweep's exact height bands, capsule
  radius, and forward distance against real map geometry.
- Exact vault natives/animation pairing for a quadruped skeleton — no
  candidate clip found in either research pass; genuinely unresolved,
  unchanged from the original draft.

---

## 12.6 — Cross-cutting notes carried forward from `SPEC.md` §9

- **§9 item 5 (PvP-balance review)** applies to every numeric value in
  §12.2's `Config.Combat` table — none of it is ready to default-enable
  without that review. With §12.0 items 5/6 (non-consensual application,
  target-eligibility) now dormant under Phase 3's NPC-only scope, this
  review's scope for Phase 3 narrows to cooldown/threshold tuning and
  §12.0 item 3's in-engine sweep tuning — it should be re-widened to cover
  items 5/6 again if a future PvP phase is ever scoped.
- Recommend looping in **config-validator** specifically on
  `Config.Combat`'s numeric knobs before Phase 3 implementation starts.
- Recommend a **coder-security** pass confirming: (a) §12.0 item 1's
  NPC-only scope is actually enforced server-side in every one of the four
  features' validation paths (never trusting a client's claim that a
  target is an NPC), and (b) §12.0 item 2's HandlerDownDefense acceptance
  criteria are met exactly as written (no code path applies state to or
  moves the K9 player's own ped without their own confirming input).
- §12.0 item 7 (handler-partnership link) still needs a human product
  decision or a dedicated design pass before `BiteAndHold`'s Recall actor
  and `HandlerDownDefense`'s handler-lookup can be finalized — this is the
  one remaining item from the original four-fork set that this revision
  could not responsibly resolve from the available evidence.

## 12.7 — Quick-reference: decisions that must be made before implementation starts

**Resolved this revision (sign-off still needed per the note at the top of
§12.0, but no longer open design questions):**
1. ~~PvP vs. PvE target scope~~ — **DECIDED: NPC-only for Phase 3**
   (§12.0 item 1). Needs a one-line human sign-off on the resulting scope
   reduction from `SPEC.md` §6.2's literal wording, not a design decision.
2. ~~HandlerDownDefense's "aggressive state" reading~~ — **DECIDED:
   UI/auto-targeting convenience, not AI takeover** (§12.0 item 2), with
   acceptance criteria now spelled out explicitly.
3. ~~AgilityAdvanced's obstacle-detection method~~ — **DECIDED:
   multi-height capsule-sweep raycast** (§12.0 item 3). Needs in-engine
   tuning of the sweep parameters before enabling by default, not a method
   decision.
4. ~~PropDragging's "is this player downed" integration point~~ —
   **NARROWED: not a Phase 3 blocker** (§12.0 item 4). Fully native for
   Phase 3's NPC-only scope; a concrete two-part integration contract
   (default metadata check + config override hook) is documented for
   whenever a future PvP phase needs it.

**Still genuinely open — needs a human decision-maker or delegated
specialist before implementation starts on the affected feature(s):**
5. Non-consensual state application posture — dormant under Phase 3's
   NPC-only scope; re-raise only if a future PvP phase is scoped (§12.0
   item 5).
6. Target-eligibility restriction (same-department griefing) — dormant for
   the same reason; re-raise only if a future PvP phase is scoped (§12.0
   item 6).
7. Handler-partnership link: reuse active leash pairing, or a new
   persistent registry? — **genuinely unresolved, blocks `BiteAndHold`'s
   3b sub-phase and `HandlerDownDefense`'s 3e sub-phase** (§12.0 item 7).
   No evidence from either research pass bears on this question; needs a
   product decision or a dedicated design pass, not a guess.
8. Native/animation verification still outstanding: the bite/attack anim's
   in-engine visual quality across breeds (§12.5.1) and the vault animation
   for a quadruped skeleton (§12.5.5) — both narrowed by
   `phase2_notes/phase3_combat_natives.md` but not fully closed.
9. `Config.Combat`'s numeric placeholders need a PvP-balance/
   config-validator pass before any flag in this phase defaults to `true`
   (§12.6).
