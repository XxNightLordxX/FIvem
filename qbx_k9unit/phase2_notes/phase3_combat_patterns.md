# Phase 3 combat mechanics — ecosystem/community-pattern research

Author: technology-scout pass, 2026-08-23, jlwood17190665@gmail.com.

Status: **pure research, read-only.** No `.lua` file, `config.lua`,
`SPEC.md`, or `PHASE3_SPEC.md` was touched to produce this document. Written
in parallel with a native-api-assistant pass researching raw native
feasibility for the same five `PHASE3_SPEC.md` features
(`BiteAndHold`, `NonLethalTakedown`, `HandlerDownDefense`, `PropDragging`,
`AgilityAdvanced`) — this document covers the different angle: how
well-regarded, shipping FiveM K9/police-dog and combat-mechanic scripts
actually implement the same or adjacent mechanics today, and whether their
patterns are worth adopting or worth explicitly avoiding, judged against
this codebase's own stated design philosophy (`SPEC.md` §2's non-goals,
§8's server-authoritative posture, the leash mechanic's "a client can only
reliably control its own ped" rule documented in `client/movement.lua` and
restated throughout `PHASE3_SPEC.md` §12.0 item 1).

This builds on, but does not re-cite wholesale, this session's earlier
Phase-2-scoped survey of Mato-K9, Rq-dogs, and v-k9 — this pass researched
the combat-mechanic angle specifically, plus non-K9 scripts (cuffing/drag,
ragdoll/knockout, bodyguard AI, parkour/vault) that are the actual closest
real-world analogs for Phase 3's four target-taking mechanics.

## Headline finding, before the per-feature breakdown

**The entire mainstream FiveM K9-script ecosystem (v-k9, empfi/QB-K9,
ND-K9, Mato-K9, Rq-dogs, and the many `qb-k9` forks) is built on a
"handler spawns/deploys an NPC dog and issues it commands" architecture —
not a player playing the dog as their own persistent character.** This
matters directly for Phase 3:

- Every K9 script with an actual bite/attack mechanic found in this pass
  (empfi/QB-K9's "attack queue system," ND-K9's "attacks only on command
  via keybind") achieves it by calling native combat/task commands
  (`TaskCombatPed`-class natives, forced anims, AI-suppression flags) on an
  NPC dog they already have full network authority over, aimed at an NPC
  suspect. This is the *NPC-target* case `PHASE3_SPEC.md` §12.0 item 1
  already describes as trivially native-controllable — the ecosystem's own
  shipped practice independently confirms that read, it isn't just this
  project's own theoretical analysis.
- **v-k9 — the one script in this survey that shares qbx_k9unit's actual
  architecture (a player plays the K9 directly, "QBCore/OX player
  controlled K9")** — has **no bite/attack/takedown/drag mechanic at all**.
  Its feature set stops at Search Player, Search Vehicle, K9 Sounds, and
  K9 Emotes. This is a genuinely useful negative result: the one
  architectural cousin to this codebase in the wild has never attempted
  the exact problem Phase 3 is trying to solve (a *player-controlled* K9
  applying a hostile, non-consensual effect to another entity), which
  means Phase 3's player-target combat questions are closer to new ground
  for this specific niche than a known-solved pattern being reinvented.
  Source: [Virgildev/v-k9](https://github.com/Virgildev/v-k9).

That single fact should raise, not lower, the bar for treating any
"combat script does X" result below as directly transferable — most of
what follows is precedent for the *NPC-target* half of each feature, or
precedent borrowed from an adjacent mechanic (cuffing/dragging, ragdoll
knockout, bodyguard AI) rather than a literal existing "player-controlled
K9 does this to another player" implementation, because that combination
essentially doesn't exist yet in the surveyed ecosystem.

---

## 1. BiteAndHold

**What was found:** empfi/QB-K9 documents an "attack queue system" letting
officers order their (NPC) K9 to engage targets, "with automatic handling
of dead or distant enemies," plus auto health regen when not in combat and
death-detection that removes the K9 ped if critically injured. ND-K9 is
documented as "the dog obeys commands and attacks only on command via
keybind, no aiming required, as the dog intelligently identifies and
engages the correct target." Both are NPC-dog-vs-NPC/player-target
combat wrappers around native AI-combat task commands — no source access
was obtainable to confirm exact natives (these are commercial/closed or
partially-documented products; not independently verified beyond their own
marketing/doc copy, flagged rather than asserted as confirmed
implementation detail).
Sources: [QB-K9 (empfi)](https://github.com/empfi/QB-K9), [ND-K9 script listing](https://www.fivemscriptcreator.org/scripts/nd-k9).

**Worth adopting:** the *shape* of what these scripts do to an NPC target
(a forced anim/task state plus AI-suppression flags, "held" until released)
is exactly `PHASE3_SPEC.md` §12.5.1's own NPC-target design — ecosystem
practice independently confirms that's the standard, native-only way to
make an NPC "look bitten and held" convincingly. No reason to invent a
different mechanism for the NPC case.

**Worth avoiding:** none of these scripts attempt (and this pass found no
evidence any mainstream script attempts) a genuine forced-bite/control-
disable on a **live player's own controls** the way `PHASE3_SPEC.md` §12.0
item 1's player-target path would require. That silence is itself the
signal: don't treat "some K9 script has an attack command" as evidence
that player-target bite-and-hold is a solved, low-risk problem elsewhere
in the ecosystem — it isn't attempted anywhere this pass could find,
which supports `PHASE3_SPEC.md`'s own recommendation to ship NPC-only
first and treat player-target as a distinct, separately-reviewed
extension rather than assuming it's a routine variant.

---

## 2. NonLethalTakedown

**What was found:** `TaskRagdollPed`-based knockdown is a long-established,
widely available FiveM pattern — multiple small open-source utilities exist
purely to toggle ragdoll on a target (`Ns718/Ragdoller-FiveM`,
`dhawton/dh_ragdoll`). The commercial "PS Scripts Knockout" product
applies a forced ragdoll plus a timecycle-modifier blur effect and
**auto-revives the target after a fixed timer** (10 seconds by default) —
a simple, common shape for a "knockout" mechanic in this ecosystem.
Sources: [Ns718/Ragdoller-FiveM](https://github.com/Ns718/Ragdoller-FiveM), [dhawton/dh_ragdoll](https://github.com/dhawton/dh_ragdoll), [PS Scripts Knockout listing](https://playertechguru-scripts.tebex.io/package/6739759).

**Worth adopting:** the base primitive (force a ragdoll task, don't invent
a custom animation) is correct and well-trodden — no reason to look for
anything more exotic than `TaskRagdollPed` for the "knock the target down"
part.

**Worth avoiding — this is the one place the ecosystem norm is *weaker*
than what `PHASE3_SPEC.md` already proposes, not stronger.** Every
"knockout"-style script found in this pass trusts a **simple trigger +
fixed-duration timer**, with no equivalent of `PHASE3_SPEC.md` §12.5.2's
server-computed "was the target actually fleeing/sprinting" precondition
gate. That's a materially lower bar than this codebase is already holding
itself to. Nothing here suggests loosening `Config.Combat.NonLethalTakedown`'s
planned server-side speed-history check to match the common "any client
trigger + cooldown" pattern — if anything, this confirms that check is a
real, above-average anti-abuse improvement worth keeping exactly as
scoped, not a redundant complication to trim for parity with what else
ships in this space.

**Not independently verified this pass (flagging, not guessing):** the
exact native/flag for suppressing fall damage during a forced ragdoll
(`PHASE3_SPEC.md` §12.5.2 also flags this as unverified) — no surveyed
script's source was accessible to confirm which specific approach
(`SetEntityProofs`, a ped-config flag, or a post-hoc health-floor
re-application) is actually used in practice; this is squarely
native-api-assistant's lane to close out, not resolved here.

---

## 3. HandlerDownDefense

**What was found:** the closest ecosystem analog is standalone
"bodyguard"/"guard NPC" resources (e.g. products marketed as "Advanced AI
Bodyguards," "AI Guards," "Advanced NPC Guards") that auto-detect a nearby
threat and have their **NPC** guard engage it via native combat AI, with a
documented passive/aggressive mode toggle. These are a real, mature
pattern for "something auto-defends a player" — but every one of them
works because the defending entity **is an NPC** the resource already
owns and can hand a `TaskCombatPed`-class command to. Source:
[Enyo Scripts "AI Guards" docs](https://enyo-scripts.gitbook.io/documentations/fivem-scripts/ai-guards) (marketing/feature-summary level only — not independently verified against source).

**Worth adopting:** nothing about the *auto-defend trigger* concept itself
is new or risky to borrow — "a threshold event (owner takes damage/goes
down) triggers a defense response" is a well-established shape.

**Worth avoiding — and this is the clearest place this session's research
should reinforce a `PHASE3_SPEC.md` position rather than add a new
option:** there is **no ecosystem precedent found for a *player-controlled*
companion automatically fighting on the player's behalf** without either
(a) the companion actually being an NPC the resource commands directly, or
(b) some literal, disclosed "AI takeover" of that player's inputs — a
pattern this codebase has already explicitly rejected as a non-goal
(`SPEC.md` §2: "this resource never spawns, possesses, or remote-controls
a K9 ped on anyone's behalf"). Every bodyguard/guard script found gets its
"automatic" behavior for free specifically *because* it isn't trying to
respect a real player's own agency over their character — that shortcut
isn't available here. This is independent, ecosystem-side confirmation
that `PHASE3_SPEC.md` §12.5.3's own recommended reading (UI-convenience/
target-preselect, player still presses the button and steers themselves)
is the only version of this feature with any real precedent for a
player-controlled entity, and the literal "automatic, zero-input attack"
reading of `SPEC.md` §6.2's wording has no comparable shipped analog to
point to as reassurance that it's a well-trodden, low-risk pattern —
because it isn't one, in this specific niche.

---

## 4. PropDragging

**What was found:** dragging an incapacitated/cuffed player is one of the
oldest, most common mechanics in the FiveM RP ecosystem — multiple
long-running cfx forum release/discussion threads on exactly this
("[Release] Drag command," "Drag/Undrag command," "Problem with
AttachEntityToEntity() in Drag function") and current maintained cuffing
resources (`DevTestingPizza/Realistic-Handcuffs-FiveM`,
`murfasa/CuffedUp`) ship drag-while-cuffed as a standard feature.
Commercial all-in-one police jobs (e.g. an rcore-based "police job
all-in-one" and "Police Essentials" by Mirror Park Studios) advertise
"drag," "escort with resistance animations," and "put a dragged player
into a vehicle" as expected baseline features of a modern cuffing system.
This pass could not retrieve actual source for the exact
`AttachEntityToEntity` call sites in the specific repos checked (GitHub's
web UI and API returned metadata/README content only for the accounts
reachable through this environment's egress rules, and `forum.cfx.re`
itself is blocked from this environment) — so the *exact* code pattern
used by any one named repo is **not independently confirmed** here, only
the existence and maturity of the feature category itself.
Sources: [Realistic-Handcuffs-FiveM](https://github.com/DevTestingPizza/Realistic-Handcuffs-FiveM), [murfasa/CuffedUp](https://github.com/murfasa/CuffedUp), [Police Essentials listing](https://forum.cfx.re/t/paid-standalone-police-essentials/4837560) (title/description only, thread itself unreachable from this environment).

**Worth adopting, with an honest caveat on how much is actually verified:**
the *existence* of years of forum discussion specifically about
`AttachEntityToEntity` fighting the network when applied to a dragged
player (the exact same "a client can only reliably control its own ped"
problem `client/movement.lua`'s header and `PHASE3_SPEC.md` §12.0 item 1
already name) is itself useful corroboration that this is a real,
long-known problem in this ecosystem, not a hypothetical concern unique to
this codebase. The community-converged fix for that whole *class* of
problem (own-client-applies-its-own-entity-attachment, driven by a
server-relayed instruction) is the same architecture the leash mechanic
here already uses and `PHASE3_SPEC.md` §12.5.4 already proposes reusing —
this pass did not find a contradicting pattern anywhere, and did not find
a repo where dragging a *player* target is done by literally attaching
from a third client without incident. Recommend treating
`PHASE3_SPEC.md`'s planned architecture as already-aligned with ecosystem
best practice here rather than looking for a different approach —
but flag plainly that this conclusion rests on the *pattern's* long
public discussion history, not on a line of source code this pass
actually read and confirmed.

**Worth avoiding:** don't copy a "drag with no way to end it" or "drag
into a vehicle forcibly" pattern some commercial listings advertise
(e.g. forcing a dragged player into a vehicle seat) without the same
no-consent-to-enter/no-consent-to-exit hygiene this codebase already
holds itself to for the leash (`SPEC.md` §6.1's hard "never trap someone
with no self-service exit" rule) — `PHASE3_SPEC.md` §12.5.4 already
carries this forward correctly; no ecosystem pattern found argues for
loosening it.

**Also worth noting (not this pass's problem to solve, but relevant
context):** the "downed" external-integration dependency
`PHASE3_SPEC.md` §12.5.4 flags is exactly how mature cuffing/laststand
integrations in this ecosystem already work in practice — most
QBCore-family police/EMS resources expose a downed/cuffed state as a
player metadata flag (commonly something shaped like
`Player.PlayerData.metadata.isdead` / `.ishandcuffed`, per widely-used
QBCore/Qbox metadata conventions) rather than a bespoke export. This is
offered as a plausible shape for whatever "is this player downed"
integration point qbx_k9unit eventually documents, **not a confirmed
export name/signature** — consistent with `PHASE3_SPEC.md`'s own explicit
refusal to invent one, and with `SPEC.md` §9 item 11's identical caveat
about unverified ox_inventory export names.

---

## 5. AgilityAdvanced (fence/window vault approximation)

**What was found, and this is the most concrete, source-verified result
in this whole pass:** `Bonzaii99/bonz_parkour`, a small open-source FiveM
parkour script, was actually readable via raw source fetch. Its vault/
flip/slide moves have **no obstacle or environmental detection at all** —
each move is unconditionally triggered on a keybind, plays a fixed
animation, and applies `ApplyForceToEntityCenterOfMass()`, gated only by
`Config.BufferTimer` (a flat post-move cooldown). There is no raycast, no
shape test, no height measurement, and no prop/zone whitelist anywhere in
the script — a player can "vault" into open air, through a wall, or over
nothing at all, with the animation playing regardless of what's actually
in front of them.
Source: [Bonzaii99/bonz_parkour](https://github.com/Bonzaii99/bonz_parkour) (source read directly via raw file fetch, not just README/marketing copy — the one fully-confirmed result in this document).

A better-precedent example for *doing detection properly* (different
mechanic, same underlying problem shape — "is there a valid surface/
obstacle here"): `invalid0190/dynamic-sit`, a raycast-based "sit anywhere"
script, is documented as using "multi-height vertical sweeps and thick
capsule scanning" to find a valid surface generically across the map
rather than relying on a single ray or a fixed whitelist. Source:
[invalid0190/dynamic-sit](https://github.com/invalid0190/dynamic-sit) (description-level detail; the multi-sweep detection logic itself was not independently read/confirmed in source this pass).

**Worth avoiding, explicitly:** `bonz_parkour`'s "no detection at all,
just play the animation" pattern is a real, shipped example of the exact
kind of naive/exploitable approach this task was asked to watch for.
Copying it (or anything shaped like it) for `AgilityAdvanced` would be a
regression from *either* option `PHASE3_SPEC.md` §12.5.5 already floats —
worse than the raycast option (a) because it does zero validation, and
obviously worse than the tagged-prop option (b) because it has no
allowlist either. This is worth naming plainly as a negative example, not
just a data point: "some community parkour scripts do this" should not be
read as license to skip obstacle validation for `AgilityAdvanced`.

**Worth adopting (directional, not a full solution):** if raycast
detection (`PHASE3_SPEC.md`'s option (a)) is the path chosen, structure it
as a **multi-height capsule sweep** in the shape `dynamic-sit` is
documented as using, rather than a single forward ray — a single ray is
exactly the kind of implementation `PHASE3_SPEC.md` §12.5.5 already
flags as carrying "real false-positive/negative risk against irregular
world geometry (a ray clipping a fence post vs. a gap between slats)";
a multi-height sweep is a concrete, better-shaped mitigation for that
named risk, worth handing to whoever implements option (a) rather than a
single-ray version. This is a refinement of an already-identified open
fork, not a new decision — the (a) vs. (b) choice itself remains
unresolved and outside this document's authority to pick.

---

## Cross-cutting takeaways for whoever picks this up next

1. **The strongest, most-repeated signal across all five features:** the
   mainstream FiveM ecosystem's answer to "how do you apply a real
   hostile effect to a live player from another entity" is, overwhelmingly,
   "you don't — you either target an NPC you already control, or you have
   the target's own client cooperate via a relayed event." Nothing found
   in this pass contradicts `PHASE3_SPEC.md` §12.0 item 1's own conclusion
   or its recommendation to scope Phase 3's first ship to NPC targets.
2. **The ecosystem's typical trust bar for "knockout"/ragdoll-style
   mechanics is lower than what `PHASE3_SPEC.md` already proposes** —
   nothing here argues for weakening the planned server-side
   speed-precondition gate on `NonLethalTakedown`.
3. **One clear negative example worth remembering by name:**
   `bonz_parkour`'s zero-validation vault/flip pattern — a concrete,
   source-confirmed instance of the "naive, exploitable pattern" this
   task was scoped to watch for, not a hypothetical risk.
4. **Genuinely new ground, not reinvention:** Phase 3's player-target
   combat questions (bite/takedown/drag applied to another real player)
   have essentially no precedent in the one architecturally comparable
   script (`v-k9`) surveyed this pass. Treat any Phase 3 player-target
   work as original design-and-review effort for this niche, not as
   "porting a known pattern," when scoping cost.
5. **Unverified/couldn't confirm, flagged rather than guessed:** exact
   source-level implementation details for empfi/QB-K9's attack queue,
   ND-K9's targeting logic, any specific cuffing script's actual
   `AttachEntityToEntity` call site, and the fall-damage-suppression
   native/flag used by any surveyed knockout script — this environment's
   egress rules blocked `forum.cfx.re` entirely and several GitHub repos
   only exposed README/metadata rather than raw source through the
   available fetch tooling. Where a claim above rests on a script's own
   marketing copy rather than source this pass actually read, it's called
   out inline rather than presented as confirmed.

## Handoff notes

- **coder-architect / native-api-assistant:** §1–2 and §5's findings are
  directly relevant to `PHASE3_SPEC.md` §12.5.1/§12.5.2/§12.5.5's own
  open native-verification items — nothing here replaces that
  verification work, but the NPC-target architecture and the
  multi-height-sweep refinement are worth folding into whichever spec
  revision follows.
- **product-manager:** §3's finding (no ecosystem precedent for a
  player-controlled companion auto-fighting without either NPC status or
  literal AI takeover) is direct, additional evidence for
  `PHASE3_SPEC.md` §12.5.3's already-recommended reading — worth citing
  if `SPEC.md` §6.2's "no manual radial input required" wording ever needs
  a firmer resolution than "recommended, not decided."
- **coder-security:** §4's corroboration that the leash-style
  own-client-relay architecture matches long-standing ecosystem practice
  for player-target dragging is relevant to whichever security pass
  reviews `PHASE3_SPEC.md` §12.0 items 1/2.
