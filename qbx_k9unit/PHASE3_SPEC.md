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
jlwood17190665@gmail.com.** §12.0's four flagged design forks were
re-examined against two research passes (`phase2_notes/phase3_combat_patterns.md`,
`phase2_notes/phase3_combat_natives.md`). That revision **decided the PvP
vs. PvE fork as "NPC-only for Phase 3."**

**Revision 3 (PvP reversal, explicit product override): product-agent,
2026-08-23, jlwood17190665@gmail.com.** The requester has explicitly
overridden Revision 2's NPC-only decision: **player-vs-player K9 combat is
now settled, in-scope work for Phase 3**, made as a deliberate, informed
choice with full awareness of the tradeoffs Revision 2 documented (no
ecosystem precedent for this exact architecture, the real cost of a
player-relay design, and the non-cooperating-client limitation inherent to
any effect that must be applied to a live player's own ped rather than an
NPC this resource fully controls). This revision does **not** re-litigate
whether PvP is a good idea — that door is closed. It rewrites §12.0 item 1
to reflect the new decision and works through every downstream consequence
Revision 2 had marked dormant/moot/narrowed specifically because of the
NPC-only framing: the client-relay architecture problem for a live-player
target (§12.0 item 8, newly surfaced and **left explicitly unresolved,
flagged blocking** — see that item for why this document does not force a
weak answer here), non-consensual state application (§12.0 item 4, now
resolved), target eligibility (§12.0 item 5, now resolved as a config-driven
gate), and PropDragging's downed-player dependency (§12.0 item 6, restored
from "narrowed/non-blocking" to a real, concrete, partially-blocking
requirement). §12.1–§12.7 are updated wherever they depended on the old
NPC-only framing. No `.lua` file was touched to produce this revision either
— still planning only, not committed.

**Revision 4 (coder-security resolution pass): coder-security,
2026-08-23, jlwood17190665@gmail.com.** Revision 3 left §12.0 item 8 —
whether a non-cooperating target client can be *prevented*, not merely
detected, from ignoring a relayed Category B combat effect — explicitly
BLOCKING and routed to coder-security/coder-architect. This revision
answers it, from a trust-boundary/exploit-resistance lens, with real
research rather than a restatement: the named network-ownership-migration
candidate is independently evaluated against FiveM's actual, documented
network-ownership model (citizenfx/fivem GitHub issues/PRs, not guesswork)
and **rejected as not viable** — not "needs a prototype," a concrete,
sourced "no." A full detection-layer design is specified in enough detail
to implement. And the actual product/architecture ship call Revision 3
declined to make — does Category B combat ship at all — is made:
**Category A ships now; Category B ships only under new, binding
guardrails specified below, never as a claimed enforced restraint against
a player target.** Item 8 below and §12.7 item 8 are rewritten to reflect
this; nothing else in §12.1–§12.6 needed rewriting, since those sections
already correctly deferred to item 8 rather than asserting their own
answer. No `.lua` file was touched to produce this revision either — this
remains a design/spec-only pass, not committed.

## Relationship to `SPEC.md` and to this project's document-scale precedent

This document is written to become `SPEC.md` §12 (immediately after §11,
Phase 2's own detailed spec) once someone with safe incremental-edit access
to that file folds it in — it deliberately uses `§12.x` numbering internally
for that reason. It is **not** folded into `SPEC.md` directly in this pass:
`SPEC.md` is already ~1,650 lines, this agent's toolset here has no
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
against `SPEC.md` directly if the two ever drift. In particular, `SPEC.md`
§2's non-goals list (which, as of Revision 2, would have gained a
"player-vs-player K9 combat is a non-goal" bullet) must **not** gain that
bullet when this document is eventually folded in — Revision 3 reverses that
specific conclusion.

**Revision 5 (coder-architect resolution pass): coder-architect,
2026-08-24, jlwood17190665@gmail.com.** The one remaining genuinely-open
item this document carried since its original draft — §12.0 item 7,
"handler-partnership link: reuse active leash pairing, or a new persistent
registry?" (extracted into its own dedicated doc,
`phase2_notes/phase3_handler_partnership_decision.md`, per that file's own
note that it is "the **one remaining item** out of PHASE3_SPEC.md's original
four cross-cutting design forks") — is resolved here with a concrete,
scoped design, not a restatement of the two options. **Decision: a new,
DB-backed "K9 partnership" registry (Option B), established by an explicit,
mutually-consented action independent of momentary leash state — reusing
`LeashPairs` (Option A) is rejected outright**, not adopted as a
lower-cost default, because Option A's disclosed gap (no defense-mode
support for an off-leash K9) is not a minor residual cost the way similar
disclosed gaps elsewhere in this document are (e.g. item 5's wanted-status
ecosystem-fragmentation caveat) — it is a failure on `HandlerDownDefense`'s
own named primary use case, an off-leash foot chase, per §12.0 item 2's own
framing of why this link is needed "independent of momentary leash state"
in the first place. See item 7 below for the full design (schema,
establish/end conditions, authorization, persistence rationale) and the
now-updated §12.1 (sub-phase ordering), §12.3 (new `server/partnership.lua`
file entry), §12.5.1/§12.5.3 (BiteAndHold's Recall actor and
HandlerDownDefense's trigger, now pointing at a concrete mechanism instead
of a hedge), §12.6, and §12.7 (quick-reference). `phase2_notes/
phase3_handler_partnership_decision.md` is updated with a resolution banner
pointing back here rather than left to read as still-open. No `.lua` file
was touched to produce this revision either — this remains a design/
spec-only pass, not committed; `server/partnership.lua` does not exist yet.

**Read §12.0 first.** Item 8 — whether a non-cooperating client can be
prevented (not merely detected) from ignoring a relayed combat effect — is
now **RESOLVED as of Revision 4** (coder-security's analysis; see item 8
below), and item 7 — the handler-partnership link — is now **RESOLVED as of
Revision 5** (coder-architect's analysis; see item 7 below). **No
`Config.Features` flag in this phase should be flipped to `true` on a live
server, and no implementation should start on
`BiteAndHold`/`NonLethalTakedown`/`PropDragging`'s player-target code paths,
until:**
- **item 8's concrete guardrails are actually built, not merely
  documented** — the detection layer specified in item 8 exists in real,
  tested code; `PropDragging`'s attach is re-asserted every tick (never
  one-shot); no server-authoritative consequence (arrest completion,
  evidence, currency, items, permissions) is ever gated on a Category B
  "effect applied successfully" signal for a player target; and every
  player-facing string describing these three mechanics against a player
  target is worded as best-effort, never as an unconditional guarantee.
  This replaces the prior "needs coder-security/coder-architect to answer
  item 8" gate — that answer now exists; what remains is implementation
  discipline, not further design,
- **item 6 (PropDragging's downed-integration contract) is actually built**
  before `PropDragging`'s player-target path ships (NPC-target dragging
  remains unblocked and can proceed independently),
- **item 7 (`server/partnership.lua`, the K9 partnership registry) is
  actually built** before `BiteAndHold`'s Recall actor or
  `HandlerDownDefense` ship (their non-Recall/non-defense-trigger paths —
  bite-and-hold's own bite/release, takedown, dragging — do not depend on
  it and are unaffected), and
- **items 1–7 get an explicit human sign-off** — they are settled
  defaults for this document, not yet a green light for implementation to
  start.

---

## 12.0 — Cross-cutting design forks: resolved and open (read this first)

### RESOLVED — settled defaults for Phase 3, pending the sign-off noted above

#### 1. PvP vs. PvE target scope — DECIDED (Revision 3, supersedes Revision 2): player-vs-player K9 combat is IN SCOPE for Phase 3

**Decision:** all four target-taking mechanics (`BiteAndHold`,
`NonLethalTakedown`, `PropDragging`, and `HandlerDownDefense`'s target
selection) ship in Phase 3 able to target **either an NPC (AI-controlled)
ped or a live player's own character**, subject to the eligibility gate in
item 5 below for player targets specifically. This is a direct, explicit
product decision, made with full knowledge of everything Revision 2's
research turned up against it — it is **not** a re-opening of that research,
and correctness-overseer should not treat "no ecosystem precedent exists for
this" or "a modified client can ignore the instruction" as grounds to flag
this decision itself as wrong. Those are exactly the tradeoffs the requester
weighed and accepted. What *is* still open, and what this revision spends
the rest of §12.0 on, is working out the concrete mechanics of that decision
honestly — in particular item 8, which this document does **not** consider
closed.

**What this changes concretely, applied throughout §12.1–§12.5 below:**
- `SPEC.md` §6.2's original wording ("target ped/player," "nearest hostile")
  is now implemented **as literally written** — no scope narrowing to
  "NPC ped" anywhere in this phase's acceptance criteria.
- Player-vs-player K9 combat is **not** a `SPEC.md` §2 non-goal, was never
  actually added as one (Revision 2 flagged it as something to add when
  folding this document in; that fold-in step must not happen now).
- Item 4 (non-consensual state application) and item 5 (target eligibility)
  — dormant under Revision 2's NPC-only framing — are **live again** and
  resolved below, not merely re-opened and left hanging.
- Item 6 (PropDragging's downed-player dependency) is restored from
  "narrowed to a non-blocking forward note" back to a real, partially
  blocking requirement for Phase 3's *player-target* dragging path
  specifically (NPC-target dragging is unaffected and unblocked).
- Item 8 is new to this revision: the client-relay architecture problem
  Revision 2's research flagged as a reason to prefer NPC-only, but never
  had to solve because NPC-only made it moot. It has to be solved (or
  explicitly left open, which is what this revision does) now that the
  decision it was an argument against has been overridden.
- Every "only if player targets are in scope" branch that Revision 2's
  §12.5 text marked "retained only as a forward design note, not scheduled
  work" is now **live, in-scope work for Phase 3**, rewritten in full below
  rather than left as a note.

#### 2. HandlerDownDefense's "aggressive state" — DECIDED: UI/auto-targeting convenience, not AI takeover

**Unchanged from Revision 2** — this decision does not depend on the PvP
scope question and stands as originally written:

`SPEC.md` §6.2's "the K9 automatically enters an aggressive state ... with
no manual radial input required" means the K9's bite-and-hold/takedown
actions become available through a single simplified, pre-targeted input
instead of navigating the radial menu first — the K9 player still steers
their own ped and still presses the confirming input themselves. The literal
alternative reading (a fully autonomous, zero-input AI attack) is rejected:
it would require this resource to take control of the K9 player's own ped,
directly conflicting with `SPEC.md` §2's standing non-goal ("this resource
never spawns, possesses, or remote-controls a K9 ped on anyone's behalf")
and §1's "The K9 player controls themselves directly, like any other player
character, at all times."

**One consequence of the PvP reversal that does touch this item:** "nearest
hostile" can now resolve to a live player, not only an NPC (see §12.5.3
below) — the acceptance criteria themselves (never moves the K9's own ped,
never fires a weapon, requires manual confirmation, goes through the same
`requestBiteHold`/`requestTakedown` validation path) are otherwise unchanged
and still fully apply regardless of what kind of entity gets pre-selected.

**Acceptance criteria (unchanged from Revision 2):**
- [ ] A HandlerDownDefense trigger **never**, by itself, moves the K9's
      ped, fires a weapon, plays a combat animation, or applies any task/
      control to the K9 player's own character. Its only effect is
      presenting a prompt and/or pre-selecting a target.
- [ ] The K9 player must still manually confirm before any bite-and-hold or
      takedown action actually executes.
- [ ] The K9 player retains full manual control of their own ped's
      movement and camera at all times.
- [ ] Once confirmed, the action goes through the exact same
      `requestBiteHold`/`requestTakedown` server validation path as a
      manually-radial-triggered action — including, now, the player-target
      eligibility gate in item 5 if the pre-selected hostile is a player.
- [ ] A literal AI-takeover version of this feature remains a separately-
      scoped, dedicated-security-review feature, not an alternate
      configuration of `HandlerDownDefense`.

#### 3. AgilityAdvanced obstacle detection — DECIDED: capsule-sweep raycast (`detectionMethod = 'raycast'`) as the Phase 3 default

**Unchanged from Revision 2** — entirely independent of the PvP scope
question (this feature never targets anything, it's the K9's own-body
locomotion). `Config.Combat.AgilityAdvanced.detectionMethod = 'raycast'`
ships as the Phase 3 default, implemented as a multi-height capsule sweep
(`StartShapeTestCapsule`/`GetShapeTestResult`, confirmed real natives per
`phase2_notes/phase3_combat_natives.md` §5). See §12.5.5 for the full,
unchanged detail.

#### 4. Non-consensual state application posture — RESOLVED (Revision 3; was dormant under Revision 2, was item 2 in the original draft)

**Question:** this codebase's one existing target-effect precedent — the
leash mechanic — is explicitly **consent-based**: attaching requires the
target's accept/decline prompt (`SPEC.md` §9 item 3b, `server/main.lua`'s
consent handshake). Bite-and-hold, non-lethal takedown, and prop dragging
are, by their nature, **not** consent-based — nobody accepts being bitten,
ragdolled, or dragged. Does shipping a non-consensual mechanic in the same
codebase conflict with the leash's consent precedent, or is this a
different category that doesn't need to satisfy it?

**Resolution: combat is a different category from leash, and does not need
the leash's consent model — this is not a conflict, it's a category
difference, made explicit here rather than left ambiguous.** The leash's
consent requirement exists because leash is a **cooperative** mechanic: two
consenting parties opt into a shared gameplay affordance (a partnered
handler and K9 working together), and nothing about it is meant to be used
against an unwilling party. Bite-and-hold, takedown, and dragging are
**apprehension/enforcement actions** by design — a K9 apprehending a suspect
is, definitionally, not something the suspect agrees to, exactly mirroring
how every comparable roleplay mechanic already in the QBCore/Qbox ecosystem
works (cuffing, tasing, hogtying, downing another player in a fight — none
of these gate on the target's consent, and none of them are expected to).
Requiring consent from a combat target would make the feature meaningless,
not safer.

**What this resolution does NOT do, though, and where the two mechanics
still rhyme deliberately:**
- Because combat gives up the leash's "consent gates getting affected"
  guarantee, the compensating control has to come from somewhere else —
  that's exactly what item 5 (target eligibility) below is for. Read items
  4 and 5 together: non-consensual-by-design is only acceptable in this
  codebase's own terms if it isn't also unrestricted-by-design (the leash's
  own hard requirement is "no mechanic may trap someone with no self-service
  way out" — an unrestricted combat target-eligibility gate would be this
  codebase's equivalent failure mode, just achieved through "anyone can be
  targeted" rather than "no exit exists").
- The leash's *other* hard guarantee — "either party can detach at will,
  with zero consent needed to get free" — has a genuine analog worth
  preserving even though the *initiating* consent model doesn't carry over:
  a combat target has no sensible "release myself" action (self-release
  makes no sense in an apprehension context — the entire point is that the
  target didn't agree to it), but the existing hard duration caps
  (`Config.Combat.BiteAndHold.maxDurationMs`, the ragdoll/damage-suppression
  window in `NonLethalTakedown`, `Config.Combat.PropDragging.maxDragDistance`)
  are this mechanic's equivalent of "no unbounded trap" — every one of these
  effects has a hard, server-enforced upper bound regardless of what anyone
  does, which is the translated form of the leash's own "nobody gets stuck
  with no way out" principle for a mechanic where the trapped party
  structurally cannot be the one who lets themselves go. This is not a new
  requirement — it was already in Revision 1/2's config sketch — but it is
  now explicitly the mechanism that satisfies this codebase's own "no
  unbounded trap" standard for a non-consensual feature, and should be
  called out as load-bearing for that reason, not just a balance knob.

#### 5. Target-eligibility restriction — RESOLVED (Revision 3; was dormant under Revision 2, was item 3 in the original draft): config-driven wanted/suspect gate

**Question:** can a K9 use bite-and-hold/takedown/drag against *any* player,
or only one meeting some in-game criteria — mirroring how a real police K9
wouldn't be deployed against an arbitrary bystander?

**Resolution: yes, restricted — gated by a new, explicit config surface,
`Config.Combat.RequireWantedStatus` (default `true`), not left undefined.**
This is the compensating control item 4 above says is load-bearing once
consent is off the table. Concretely:

- When `Config.Combat.RequireWantedStatus = true` (the shipped default), a
  K9 may only initiate `BiteAndHold`, `NonLethalTakedown`, or `PropDragging`
  against a **player** target who is currently flagged wanted/suspect by
  whatever dispatch system the target server actually runs. This check
  applies to player targets only — an NPC target is unaffected by this
  flag either way (a "wanted" concept doesn't meaningfully apply to an NPC
  the resource has no reason to protect from griefing in the first place).
- **There is no native GTA/FiveM concept of a networked player's "wanted
  level"** the way single-player has one (that stat is not part of the
  networked ped model), and unlike PropDragging's laststand check (item 6),
  there is **no single ecosystem-dominant convention** for how a "wanted"
  flag is exposed — dispatch resources are meaningfully more fragmented
  across servers (cd_dispatch, ps-dispatch, qs-dispatch, and plenty of
  in-house systems, each with their own state shape) than laststand/EMS
  metadata tends to be. Flagging this explicitly as **lower confidence**
  than the PropDragging metadata guess in item 6, not the same strength of
  claim.
- **The concrete integration point this document commits to**, following
  the exact same two-part shape already established for PropDragging's
  downed-check (item 6 below, and originally `SPEC.md` §2's "exports/events
  will be exposed so such integration is possible, but no particular
  external resource is assumed to exist" posture):
  1. A best-effort default check against a plausible common metadata
     convention (e.g. `metadata.wanted` / `metadata.iswanted`, if the
     player's data structure exposes something shaped like it) — used
     automatically with no server-side setup, but flagged, per the
     confidence note above, as more likely to need overriding than
     PropDragging's equivalent default.
  2. An explicit override hook, `Config.Combat.WantedStatusCheckOverride`
     (function(playerId) -> boolean), for a server to wire directly to its
     actual dispatch resource's real export/state — expected to be the
     **normal**, not exceptional, path for a real server given item 5's own
     fragmentation note above.
  3. `Config.Combat.RequireWantedStatus = false` remains available for a
     server owner who deliberately wants unrestricted PvP K9 combat — but
     the shipped default is `true` (secure/restrictive-by-default), matching
     this project's general posture on anything gating a real capability
     (`HasK9Access`'s own default-deny framing throughout §4).
- **Enforcement point:** server-side only, inside `requestBiteHold`/
  `requestTakedown`/`requestDrag`'s validation, alongside every other check
  already specified there (never a client-side-only gate) — reject with a
  `not_eligible_target` reason when the target is a player,
  `RequireWantedStatus` is true, and the check fails.
- **Same-department griefing (the original draft's item 3 framing)**: this
  gate substantially — but not completely — closes that door. A fellow
  officer in normal standing wouldn't independently be flagged wanted by a
  legitimate dispatch flow, which removes the common accidental case. It
  does **not** close a deliberate abuse case where an officer manipulates
  their own server's dispatch/wanted system to flag a colleague — that is an
  abuse vector of whatever *other* resource controls the wanted state, not
  something `qbx_k9unit` can or should try to independently re-verify (same
  "don't try to solve someone else's resource's security" posture already
  applied to the PiP-feed and prop-asset non-goals in `SPEC.md` §2). Flagging
  this residual gap explicitly rather than claiming the eligibility gate is
  airtight.

### RESTORED — no longer moot, a real (partially blocking) requirement again

#### 6. PropDragging's "is this player downed" integration point — RESTORED (Revision 3; was "narrowed, non-blocking" under Revision 2, was item 4 in the original draft)

Revision 2 concluded this was made moot for Phase 3's *initial* ship because
NPC-only scope let `PropDragging`'s "downed" check be fully native
(`IsPedDeadOrDying(ped, true)` + `IsPedRagdoll`). Item 1's reversal removes
that scope carve-out, so this returns as a real, partially blocking
requirement for `PropDragging`'s **player-target** path specifically. NPC-
target dragging is unaffected and can proceed on schedule regardless of how
this item resolves.

**The native-surface gap, restated concretely (not just "depends on the
target server"):** `IsPedDeadOrDying`/`IsPedRagdoll` are real natives and
will technically execute against a player's ped without erroring — but they
do not answer the actual game-design question this feature needs answered
("is this specific player currently in *this server's own scripted*
downed/laststand state, such that dragging them is the intended use of this
mechanic"), independent of whether the native calls themselves succeed.
Concretely, this produces both failure directions, not just one:
- **False negatives:** most QBCore/Qbox laststand implementations
  deliberately keep the player's ped alive (health above zero, no native
  death state entered) while a custom animation and EMS-job-gated
  input restriction run entirely in script — `IsPedDeadOrDying` would
  return `false` for a player who is, by every game-design definition that
  actually matters here, "downed."
  - **False positives:** a player who is simply ragdolled for an unrelated
  reason (knocked over by a vehicle, an explosion, an unrelated fistfight)
  would satisfy `IsPedRagdoll` without being "downed" in any sense this
  feature should care about, making them incorrectly draggable.

Because of this, the native check that Revision 2 correctly identified as
sufficient for an NPC target is **not** sufficient for a player target, full
stop — this isn't a confidence gap that more native research would close,
it's a category mismatch between what the natives observe (raw physics/AI
state) and what the feature needs to know (this server's own scripted
game-state concept of "downed").

**The concrete integration contract this document commits to (same shape
as before, now REQUIRED rather than forward-looking for the player-target
path):**
1. A default check against the common Qbox/QBCore metadata convention —
   read `metadata.isdead` / `.inlaststand` (or a similarly-named laststand
   flag) if the player's data structure exposes it — used automatically
   with no server-side setup for the common case. Higher confidence than
   item 5's wanted-status equivalent, per `phase2_notes/phase3_combat_patterns.md`'s
   confirmation that this is how mature cuffing/laststand integrations
   already work in practice across the ecosystem.
2. An explicit override hook, `Config.Combat.PropDragging.IsPlayerDownedOverride`
   (function(playerId) -> boolean) — must exist as a real, wired-in,
   uncommented config surface at implementation time (Revision 2 had this
   commented out as inert, since NPC-only scope meant nothing would ever
   call it; that can no longer be true once player-target dragging is
   built), for any server running a non-standard EMS/laststand system.
3. **What this unblocks vs. what it still blocks:** `PropDragging`'s
   NPC-target path remains fully unblocked (§12.1's 3d sub-phase can start
   on schedule). Its player-target path is blocked specifically on step 1
   above existing in real, tested code (not just documented) before that
   path is enabled — an explicit, small, well-scoped piece of work, not an
   open-ended unknown the way it was in the original (pre-Revision-2) draft.

### NO LONGER OPEN — item 7 resolved this pass; item 8 already resolved (Revision 4)

This section heading originally read "STILL OPEN — genuinely unresolved,
one of them explicitly blocking." As of Revision 5, both items formerly
listed here have a real, concrete resolution (item 8 in Revision 4, item 7
below in Revision 5) — the heading is updated rather than left describing a
state that no longer exists, per this document's own standard of not
leaving stale framing around a resolved fork (see how Revision 3/4 already
rewrote item 1's and item 8's own headers rather than merely appending a
new verdict underneath old wording).

#### 7. Handler-partnership link: reuse active leash pairing, or a new persistent registry? — RESOLVED (Revision 5, coder-architect): new persistent registry (Option B), not a reuse of `LeashPairs`

**Why this couldn't be closed by more research, and why it's closed by
design work instead.** Neither `phase2_notes/phase3_combat_patterns.md` nor
`phase2_notes/phase3_combat_natives.md` surfaced anything about how other
K9/handler-pair scripts model an ongoing partnership link independent of a
leash-equivalent mechanic, because — as
`phase2_notes/phase3_handler_partnership_decision.md` already correctly
diagnosed — the surveyed ecosystem is overwhelmingly a
handler-commands-NPC-dog architecture, where "who is the handler" is
trivial and definitionally always true. That precedent genuinely does not
transfer to this codebase's player-plays-the-dog model. This was never a
research gap that a third combat-pattern survey would close; it is a
product/design fork this document owed a real answer to, the same way item
1 (PvP scope) and item 5 (target eligibility) needed a decision rather than
more research. This revision makes that decision and does the scoped design
pass the dedicated doc asked for, rather than leaving "(a) or (b), your
call" standing.

**Decision: Option B — a new, DB-backed "K9 partnership" registry,
established by an explicit, mutually-consented "Partner Up" action,
independent of momentary leash state.** Option A (reuse `LeashPairs`) is
evaluated below and **rejected outright**, not merely deprioritized as the
lower-cost default the dedicated doc offered.

**Why Option A is rejected, not just costed against Option B:**
- `server/main.lua`'s `LeashPairs` is explicitly ephemeral, in-memory,
  session-scoped state for a *movement-restriction* mechanic (see that
  file's own header: "this is a live session mechanic, not part of the
  certification/permission system"). Reusing it for "who is my ongoing
  combat partner" would silently repurpose a Phase 1 mechanic's transient
  state as if it were a durable relationship, which it was never designed
  to be and does not behave like (it is torn down on distance
  safety-valve, on either party's own detach, on cert revoke, on job
  change — see `certifications.lua`'s `ForceDetachLeashIfOnline`/
  `ForceDetachOfficerLeashForSource` call sites).
- More importantly: `HandlerDownDefense`'s own motivating scenario (per
  §12.0 item 2's framing, restated in the task that produced this
  revision: "who is this K9's handler right now, independent of momentary
  leash state — the leash is transient/consensual and gets detached
  constantly during normal gameplay") is, concretely, a foot chase — a K9
  pursuing a fleeing suspect while its handler, now alone, takes damage
  supporting that chase from a distance or securing the scene. A K9 is
  routinely, deliberately unleashed for exactly this kind of active work
  (leash's own movement-restriction nature makes it actively
  counterproductive to keep attached during a chase). This means Option A
  would leave `HandlerDownDefense` **non-functional for the scenario the
  feature exists to cover**, working only in the comparatively rare case
  where the pair happens to still be leashed at the moment the handler
  takes damage. That is not the same shape as this document's other
  accepted, disclosed gaps (compare: item 5's wanted-status
  ecosystem-fragmentation caveat still lets the eligibility gate do its
  job in the overwhelming common case; item 8's non-cooperating-client gap
  still leaves the feature meaningfully working against a compliant
  target, which is the common case). Shipping Option A under the label
  "handler-partnership link, resolved" would be presenting a check that
  looks like it does the job while not doing it for the case that matters
  most — the exact class of shortcut this document's own established bar
  (already applied in items 4, 6, and 8 above) refuses to accept when a
  real alternative is buildable. One is, here: Option B.
- Cost is real but not prohibitive: the dedicated doc's own "Cons" list for
  Option B (what establishes/ends a partnership, whether it persists, DB
  table or ephemeral, who's authorized) is exactly the scope this revision
  works through below, using patterns this codebase has already reviewed
  and shipped (`k9_certifications`' schema conventions, leash's own consent
  handshake) rather than inventing new ones.

**The concrete design (scoped, not left abstract):**

1. **Establishment — mirrors leash's own consent handshake, not
   certification's grant hierarchy.** A new "Partner Up" action, initiated
   by either party (K9-role or officer-role) against the other, requiring
   the *other* party's explicit accept/decline — reusing the exact
   `PendingLeashRequests`-style pattern (`server/main.lua`) already
   reviewed and shipped for leash-attach: a TTL'd pending-request slot, one
   live request per target at a time, consumed on any response. This is a
   deliberate reuse of the **consent** precedent (unlike combat's own item
   4 resolution, which explicitly opted out of consent for a different
   reason) — designating an ongoing partner is a cooperative relationship
   between two willing parties, exactly like leash, not an apprehension
   action against an unwilling one. Eligibility at establishment time,
   re-verified server-side exactly like `CheckLeashEligibility`: both
   parties currently pass `HasK9Access`-equivalent checks for the same
   department, live proximity (reuse `Config.CertifyProximityMeters` or a
   dedicated `Config.Combat.PartnerProximityMeters` — implementer's call,
   not a design fork), and the K9-role party is currently on a configured
   K9 model (`IsConfiguredK9Model`, already exposed globally by
   `certifications.lua` for exactly this kind of reuse).
2. **Persistence — DB-backed (new `k9_partnerships` table), not ephemeral
   like `LeashPairs`.** This is the crux of why Option B differs
   structurally from Option A rather than just relabeling the same shape:
   the entire reason this registry needs to exist is to survive precisely
   the moments `LeashPairs` does not — including a resource restart
   mid-shift, which an in-memory-only table could never recover from (no
   physical/game state exists to reconstruct a partnership from the way,
   say, a still-attached leash's own game state could theoretically hint
   at a pairing). `server/certifications.lua`'s `onResourceStart` backfill
   loop already establishes the pattern this resource uses for exactly
   this class of problem (DB-backed state repopulating an in-memory cache
   for already-connected players after a restart) — `k9_partnerships`
   should follow the same shape: schema modeled directly on
   `sql/install.sql`'s `k9_certifications` conventions (append-mostly
   audit rows, an `active` flag, `established_by`/`ended_by`
   citizenid columns, a generated-column unique constraint analogous to
   `active_cert_key` — here needing **two** such constraints, since both
   "at most one active partnership per K9 citizenid" and "at most one
   active partnership per handler citizenid" must hold, unlike
   certification's single `(citizenid, job)` invariant), an in-memory
   cache (`Partnerships[citizenid] = { partner = partnerCitizenid, isK9 =
   boolean, active = true }`, refreshed via a `RefreshPartnershipCache`
   modeled on `RefreshCertificationCache`'s own pcall/fail-closed
   discipline), and a `PlayerLoaded`-driven refresh plus an
   `onResourceStart` backfill loop mirroring `certifications.lua`'s. This
   is a real, actually-new design surface (as the dedicated doc correctly
   flagged) but every piece of it is a direct application of a pattern
   this codebase has already designed, reviewed, and shipped once — not a
   novel invention.
3. **Termination — either party can break it at will, no consent needed to
   exit, PLUS automatic teardown on the same triggers that already force-
   detach a leash.** Mirrors leash's own hard "no unbounded trap" rule
   (§12.0 item 4's own restatement of that principle), now also applied to
   a persistent relationship rather than only a transient one. Automatic
   teardown call sites: add a `ForceBreakPartnershipForSource`-equivalent
   call alongside every existing `ForceDetachLeashForSource`/
   `ForceDetachOfficerLeashForSource` call site in
   `server/certifications.lua` (K9-role cert revocation, either party's
   department change) — the exact call-site list that file already
   maintains for leash, extended with one more line per site rather than a
   new independent mechanism. Character deletion is a real edge case this
   revision does **not** scope further — flagged for whoever implements to
   check qbx_core's actual character-deletion hook shape, rather than
   guessed at here, matching this document's own established practice
   (e.g. item 5's honest "lower confidence" flag) of not inventing detail
   it can't back up.
4. **Authorization — mutual consent only, no certifier-grade hierarchy.**
   Unlike certification granting (which needs a rank/grade check because it
   *is* the permission system, §4.2), partnership is a peer relationship
   between two parties who are each already independently eligible
   (department membership / K9 model) — mutual consent is the correct and
   sufficiently-scoped gate here, matching leash's own authorization model,
   not certification's.
5. **New feature flag and file:** `Config.Features.HandlerPartnership`
   (recommended default `true`), following this resource's own established
   one-flag-per-mechanic convention (`LeashMechanics` has its own flag
   despite being just as foundational) rather than piggybacking on
   `BiteAndHold`'s or `HandlerDownDefense`'s flags — a server should be
   able to disable partner-designation independently (e.g. one that wants
   `BiteAndHold`'s Recall restricted to active-leash teams only, without
   exposing a persistent "partner up" action at all). New file,
   `server/partnership.lua` — see the updated §12.3 file/module plan below.
6. **Why not a lighter, ephemeral-but-detach-independent middle option**
   (an in-memory table that simply isn't cleared on leash-detach, without a
   full DB table)? Considered and rejected: it would leave exactly the same
   restart-survivability gap Option A leaves, just relabeled — the reason
   this resolution reaches for a DB-backed store instead of another
   in-memory table is specifically that a real handler/K9 partnership is a
   session-spanning (plausibly shift-spanning) relationship by design
   intent, matching `k9_certifications`' precedent for "state that must
   survive a restart and be independently checkable," not `LeashPairs`'
   precedent for "state that only needs to survive as long as this exact
   session's live physical mechanic does."

**Consumers, made concrete (see §12.5.1/§12.5.3 for the full per-feature
text):**
- `BiteAndHold`'s Recall actor: server-side, checks
  `Partnerships[recallerCitizenid].active and Partnerships[recallerCitizenid].partner == heldK9Citizenid`
  in addition to (never instead of) an active hold-state entry already
  existing — never client-claimed.
- `HandlerDownDefense`'s trigger: on a certified handler's health crossing
  `handlerHealthThreshold`, look up `Partnerships[handlerCitizenid]`; if an
  active partnership resolves to a K9 citizenid who is currently online,
  notify that K9's client per the existing §12.5.3 event contract. If no
  active partnership exists (never partnered, or partnership broken), this
  is a **silent no-op** — `HandlerDownDefense` now has a real, disclosed
  prerequisite (an established partnership) distinct from mere
  certification, which should be stated plainly in any player-facing
  documentation/README update once implemented, not left implicit.

**Sub-phase impact (§12.1 updated below):** 3b (`BiteAndHold`) and 3e
(`HandlerDownDefense`) are no longer blocked on an open design question —
they are now blocked on `server/partnership.lua` existing as real, tested
code, the same "concrete, scoped, buildable prerequisite" shape as item 6's
resolution for `PropDragging`'s player-target path, not an unresolved
unknown.

**Still needs the same human sign-off already required for items 1–5**
(per this document's own opening note) before implementation starts — this
resolution supplies the missing design, it does not add a new gate beyond
the one this document already asked for.

#### 8. The client-relay architecture problem for a live-player target — RESOLVED (Revision 4, coder-security); was NEW/BLOCKING under Revision 3

This is the item Revision 2's research treated as an argument *against* the
PvP decision; now that the decision has been made anyway, this document owes
an honest, concrete answer about how the three target-taking mechanics
actually work against a live player, and what happens when that player's
client doesn't cooperate. Revision 3 wrote up the architecture problem in
full and correctly declined to fake an answer it couldn't back up. This
revision (coder-security, from the trust-boundary/exploit-resistance lens
this problem actually lives in) closes the two things Revision 3 left
open: whether the named enforcement candidate is viable (it is not, for
concrete, sourced reasons below — this is not a restatement of Revision 3's
own hedge), and what this resource should actually ship given that answer
(a real decision, made below, not deferred again).

**Why this is fundamentally different from anything already shipped in this
codebase.** Every existing effect this resource applies to *another* entity
falls into one of two categories, and the difference between them is the
whole story here:

- **Category A — effects an "owning" client can impose on another entity
  from outside it**, e.g. `AttachEntityToEntity` (already used safely in
  this exact codebase by `client/vehicle.lua` to load the K9's own ped into
  a vehicle). Attaching one entity to another is a state that the *calling*
  client can establish and that then replicates across the network — it
  does not require the *attached* entity's own client to run any code at
  all to take initial visual/positional effect for other observers.
- **Category B — effects that are only real when the *target's own client*
  executes a local-only native on itself.** `DisableControlAction` (already
  used by `client/movement.lua`'s `AgilityBasicJump` suppression thread, but
  always applied by a client to *itself*), `SetPedToRagdollWithFall`,
  `SetPedMoveRateOverride`, and `SetEntityCanBeDamaged` bracketing all fall
  here for the specific purpose this document needs them for. Nothing in
  FiveM's scripting surface lets the server, or some other client, force a
  *different* client's ped to stop responding to sprint/fire input, or force
  that specific ped into a ragdoll state, the way it can for an NPC the
  server or any client fully owns and commands via `TaskCombatPed`-class
  natives. The leash mechanic's own header comment in `server/main.lua`
  already states the general principle plainly, for a cooperative case:
  *"That restriction logic runs entirely client-side, on the CONSTRAINED
  player's OWN client (a client can only reliably control its own ped's
  position...)"* — Category B is that same limitation, applied to a target
  who has no reason to cooperate at all.

Bite-and-hold and non-lethal takedown's actual restrictive effects are
**entirely Category B**. Prop dragging is **mixed**: the initial physical
attach/yank is Category A (the K9's own client calling
`AttachEntityToEntity(targetPed, k9Ped, ...)` genuinely can move a target
ped's rendered position for everyone, regardless of that target's
cooperation — this is the same technique underlying widespread ecosystem
cuffing/carry scripts), but the **speed limitation** that stops the target
from simply walking off (`SET_PED_MOVE_RATE_OVERRIDE`) is again Category B —
a move-rate override on a ped is a local-only effect that must be applied by
that ped's own client to mean anything.

**Concrete event/relay design for each mechanic against a player target**
(this part is not ambiguous — it's the compliance question below that
isn't):

- **BiteAndHold:** `qbx_k9unit:server:requestBiteHold` (targetNetId) is
  extended to accept a player-owned ped's netId. The server resolves the
  entity and determines player-vs-NPC via `IsPedAPlayer(targetPed)` (never a
  client-supplied flag) — if player-owned, item 5's eligibility check
  additionally applies. On success, the server sends a new event,
  `qbx_k9unit:client:applyBiteHold` (holderNetId, expiresAt), **specifically
  to the target's own client** (`TriggerClientEvent(event, targetServerId,
  ...)` — never a broadcast). The target's client (a new handler in
  `client/combat.lua`, registered unconditionally for every player, see
  §12.3) applies `DisableControlAction(0, INPUT_SPRINT, true)` and
  `DisableControlAction(0, INPUT_ATTACK, true)` every frame for the
  duration, mirroring `AgilityBasicJump`'s exact "must reassert every frame"
  discipline, and plays a local reaction animation.
- **NonLethalTakedown:** `qbx_k9unit:server:requestTakedown` similarly
  extended. On success, the server sends `qbx_k9unit:client:forceRagdoll`
  (expiresAt) to the target's own client, which calls
  `SetPedToRagdollWithFall` on itself and applies the
  `SetEntityCanBeDamaged(false)`/`(true)` bracket on itself for the window
  (both are Category B effects, both must run on the entity's own owning
  client to mean anything for that entity).
- **PropDragging:** `qbx_k9unit:server:requestDrag` extended, gated
  additionally on item 6's downed-check for a player target. The initial
  attach (Category A) is executed by the **K9's own client**, which already
  fully controls this action — no relay/compliance problem exists for the
  attach itself. The **speed-limiting** half is relayed to the target's own
  client the same way as the other two mechanics (a new
  `qbx_k9unit:client:applyDragSpeedLimit` event), which is where the same
  compliance question below reapplies.

**New finding (Revision 4), sharpening the Category A/B split for
`PropDragging` specifically — the attach is robust against a passive
target, but not against an actively resisting one, unless it is
continuously re-asserted.** `AttachEntityToEntity`/`AttachEntityToEntityPhysically`
are documented (citizenfx/fivem GitHub issue #3726, "AttachEntityToEntityPhysically
can be abused to move/attach players") to require **no network ownership or
authority over the target entity at all** to take initial effect — real,
independent confirmation that the doc's Category A claim for the initial
attach is technically sound, and the same property already underlies
widespread ecosystem cuffing/carry scripts. But `DetachEntity` is the
symmetric operation on the same entity, and by that same evidence (no
ownership check gates the attach side) there is no reason to expect the
detach side is gated any differently — **a hostile target's own client can
plausibly call `DetachEntity` on itself at any moment to instantly break
free**, exactly the same way a hostile target ignores a Category B relay
event, just via a different native. This means `PropDragging`'s attach must
be **re-asserted every tick from the K9's own client** (call
`AttachEntityToEntity` again each frame the drag is active, not once at
drag-start) to survive a target repeatedly self-detaching — mirroring the
discipline `phase2_notes/phase3_combat_natives.md` §4 already requires for
`SET_PED_MOVE_RATE_OVERRIDE` (must be looped, not one-shot). Read "the
attach itself is Category A, no relay problem exists for it" above as true
only under this every-tick-reassert discipline — a one-shot attach
implementation would silently degrade dragging's supposedly Category A half
into something a hostile target can defeat as trivially as a Category B
effect, for the cost of one line of client Lua. **This is now a concrete,
binding implementation requirement for `PropDragging`** — see the
guardrails list at the end of this item.

**The honest answer to "what happens when the target's client simply
ignores the instruction," worked through rather than hand-waved:**

1. **Purely cosmetic, no server-enforced restriction, is explicitly
   rejected as the answer** for the reason the task framing already
   anticipates: this codebase's own standard (already applied to reject
   `SET_ENTITY_INVINCIBLE` for fighting the takedown's own ragdoll, and to
   the door-interaction lock-state non-check) is to never ship a safety/
   validity check that fakes real validation when a real one exists or is
   buildable, or — by direct extension — to describe an effect as a
   restriction when it structurally isn't one against a hostile client.
   This document will not describe Category B effects as "restraining" a
   player in any player-facing copy without that caveat attached (see the
   recommendation at the end of this item).
2. **Is a non-cooperating target detectable server-side? Yes — and here is
   the concrete, implementable design, not a sketch.** The server already
   receives authoritative position updates for every networked entity,
   including a player's own ped (this is the same fact `NonLethalTakedown`'s
   server-computed speed gate in §12.5.2 already relies on for NPCs — it is
   equally true for players, since FiveM's networking model syncs position
   to the server for any entity, not just ones the server itself commands).

   **State:** add a `compliance` sub-record to the same ephemeral hold/
   ragdoll/drag-state entry `server/combat.lua` already owns per active
   effect (do **not** stand up a separate file/table for this — the
   sampling is inherently keyed to the same per-effect lifecycle, and that
   entry already has to be cleaned up on release/timeout/disconnect
   regardless; adding a second, independently-lifecycled table for the same
   window is the kind of unforced duplication `server/tracking.lua`'s own
   `TrackableLog`/cooldown-table conventions in this codebase deliberately
   avoid). `compliance = { baselinePos = vector3, baselineTime = ms, lastPos
   = vector3, lastTime = ms, consecutiveViolations = 0 }`, stamped at
   window-open using the target's live `GetEntityCoords`/`GetGameTimer()` —
   never a client-reported value, same discipline as every other
   position read in this resource.

   **Sampling:** one ticking thread (not one thread per active effect,
   mirroring `PruneTrackableLogs`'s single-pass-over-a-shared-table
   discipline in `server/tracking.lua` rather than spawning per-entry
   threads) scans every currently-active `BiteAndHold`/`forceRagdoll`/
   `applyDragSpeedLimit` entry every `Config.Combat.NonComplianceDetection.positionSampleWindowMs`
   and computes `dist(lastPos, currentPos) / (currentTime - lastTime)` as an
   effective observed speed for that interval, then updates `lastPos`/
   `lastTime` for the next tick.

   **Per-effect threshold logic — deliberately not one generic "speed >
   X" rule, because "compliant" doesn't mean the same thing for all three
   effects:**
   - `BiteAndHold`: a compliant held target is near-stationary (may turn in
     place). Flag when observed speed exceeds an idle-jitter ceiling
     (~0.3 m/s) by more than `speedTolerance` for **two or more consecutive
     samples** (not a single sample — one sample alone is exactly the kind
     of lag/interpolation-jitter false positive this codebase's own
     "never auto-punish on a single noisy signal" instinct, already visible
     in `server/tracking.lua`'s FORGED TRAIL DECISION reasoning below,
     should avoid). **The shipped placeholder `speedTolerance = 1.0` in
     §12.2 is too loose for this specific check** — 1.0 m/s of slack on top
     of a ~0.3 m/s ceiling would let a target walk (not even sprint) through
     most of a hold window undetected. Recommend tightening to ~0.5 m/s for
     `BiteAndHold` specifically when config-validator reviews §12.2 (this
     document flags the number, not a final tuned value).
   - `NonLethalTakedown`: a genuine ragdoll produces noisy, non-directional
     per-tick velocity (falling, sliding down a slope) that a naive
     continuous speed check would false-positive on — the same problem
     `Config.Combat.NonComplianceDetection`'s single flat threshold cannot
     honestly solve for this effect. Use **net displacement across the
     whole window** (position at window-open vs. window-close/release) as
     the primary signal instead: a target who ends up materially farther
     from their ragdoll-start point than physics-driven tumbling plausibly
     explains, in a sustained consistent heading rather than random
     tumbling drift, is the stronger tell. This is a heuristic, not a
     guarantee, and must be documented as one in `server/combat.lua`'s own
     comments — do not let it read as more certain than it is.
   - `PropDragging` speed-limit half: compare the target's position against
     the **K9's own live position**, not an absolute speed ceiling — while
     properly attached and rate-limited, the target's position should track
     the K9's within a small, bounded slack (attachment offset plus normal
     sync jitter). Flag when that gap grows beyond the slack, **regardless
     of cause** (self-detach, a bypassed move-rate override, or the K9's own
     client failing to re-assert the attach) — this is a cleaner, single
     unified signal than trying to distinguish which specific native the
     target's client ignored, and it also catches the every-tick-reassert
     failure mode flagged above as a new finding.

   If Phase 2's `relayWeaponFire` tracking infra (`server/tracking.lua`) is
   enabled, a weapon-fire event observed from the target during an active
   `BiteAndHold` window remains an additional, more direct signal, as
   Revision 3 already noted — reuse it as a second input into the same
   `compliance` record rather than a separate system.

   **On violation:** `Config.Combat.NonComplianceDetection.action`'s
   `'log' | 'notify_staff'`-only default (never `'auto_kick'`/`'auto_ban'`)
   is **confirmed, not just carried over** — this matches
   `server/tracking.lua`'s own precedent for exactly this class of decision
   (that file's "FORGED TRAIL DECISION" explicitly accepts a documented,
   unclosed forgery gap for blood/gunpowder logging rather than degrade a
   legitimate feature with corroboration that would false-positive on real
   players wearing armor or switching weapons) — a server-side position/
   velocity heuristic sampled every 250–500ms over OneSync **will** produce
   occasional false positives from ordinary lag/desync, and this resource
   has no standing to auto-punish on that basis. Going one step further
   than Revision 3's recommendation, though: add
   `Config.Combat.NonComplianceDetection.OnViolationOverride =
   function(playerId, effectType, evidence) end` (optional, nil by default)
   — the same override-hook shape already established twice in this same
   document (`WantedStatusCheckOverride`, `IsPlayerDownedOverride`) — so a
   server that *does* want automated response (e.g., wiring flagged
   accounts into its own anti-cheat/admin-alert resource) can build that
   themselves on top of real evidence, without this resource ever taking a
   punitive action on its own initiative.

   **Anti-cheat false-positive note (this reviewer's own lens):** this
   detection layer is pure server-side bookkeeping against already-synced
   position data — it calls no new client native, freezes nothing, and
   teleports nothing. It introduces **zero** new anti-cheat exposure on
   either the target's or the K9's client, unlike the enforcement candidate
   evaluated in point 3 below.

3. **Is there a third mechanism that actually enforces it? Evaluated in
   detail — no, and this is a concrete, sourced "no," not "hasn't been
   prototyped yet."** Revision 3 named forced server-side network-ownership
   migration of the target's ped to a cooperating client as an unevaluated
   candidate. Independently researched against FiveM's actual, documented
   network-ownership model (citizenfx/fivem GitHub issues/PRs — the closest
   thing to authoritative source available with the official native-docs
   site unreachable from this environment) rather than assumed from memory:

   - **The cooperative request path (`NetworkRequestControlOfEntity`,
     already a confirmed-real native in this codebase's own
     `phase2_notes/phase3_combat_natives.md`, used there for the *NPC*-target
     path) is fundamentally a best-effort ask of the current owning
     client, not a server-forceable operation.** citizenfx/fivem issue
     #3338 ("Bugged entity ownerships") documents this failing outright
     "as the current owner is not aware of the entity" under ordinary
     streaming conditions — for entities the current owner *is* actively
     running code for (which describes every live player's own ped, by
     definition, for as long as that player is connected), the migration
     depends entirely on that owning client's cooperation to relinquish.
     There is also a documented client-side native
     (`SetEntityIgnoreRequestControlFilter`-class) that lets the *current*
     owner opt out of incoming control requests — meaning a hostile,
     modified client has a first-class, standard way to make itself immune
     to this technique, with zero server-side visibility into whether it
     did. A request-based approach cannot be relied on against exactly the
     adversary this item is about.
   - **There is no shipped, server-forceable alternative.** The closest
     candidate, a server-side `NetworkSetEntityOwner` native, was proposed
     in citizenfx/fivem PR #2312 and **remains unmerged** — FiveM's own
     maintainers call it "a somewhat undesirable command" carrying "risk of
     side effects," and testing in that PR's own discussion found it
     already misbehaves for *population* entities (automatic reassignment
     fighting the manual one) — a category the maintainers themselves
     declined to ship reliable forced-ownership tooling for, and that PR's
     discussion never even reaches the harder case (a live player's own
     ped) before stalling. If the FiveM project's own maintainers won't
     ship forced ownership reassignment for the *easier* case, this
     resource has no basis to assume a workable, unreviewed variant of the
     same idea exists for the *harder* one.
   - **The structural reason this isn't merely "unshipped yet," but
     fundamentally the wrong shape of fix:** a live player's own ped is not
     "an entity someone happens to own," the way a vehicle or NPC is —
     the owning client *is* the machine translating that specific human's
     real input (movement, camera, weapon fire) into that ped's simulated
     state, every frame, for as long as that human is connected. That is
     not a flag that migrates; it is what "being that player's client"
     means in FiveM's architecture. Even in the best case where a control
     request somehow succeeded, the target's own client keeps existing and
     keeps processing that human's real local input — because the entire
     scenario under discussion is a *hostile* client, it has every reason
     to keep doing so, and to re-request/re-assert control back
     immediately. This produces, at best, the rubber-banding tug-of-war
     Revision 3 already flagged even for a *cooperating* target (a real,
     independently documented ecosystem problem in existing cuffing/carry
     scripts) — and against a genuinely hostile target, there is no reason
     to expect the tug-of-war resolves in the officer's favor at all, since
     the target's client controls exactly the resource (its own
     re-assertion of local input authority) being contested.
   - **Anti-cheat angle (this reviewer's own lens, and an independent reason
     to close this off even setting the above aside):** deliberately
     fighting another client for entity control every frame — repeated
     forced position/authority reassignment against that client's own
     locally-driven input — is precisely the rapid position/authority-
     change pattern this project's own anti-cheat-false-positive standard
     warns against normalizing. Here it would not even be a *false*
     positive: to any anti-cheat heuristic (this server's own or a
     third-party one), a ped whose position is being externally
     overridden against its owning client's own input is indistinguishable
     in shape from an actual teleport/position-desync exploit. Building a
     combat feature whose enforcement mechanism *is* that pattern is not an
     acceptable trade against a false-positive risk this project otherwise
     takes seriously elsewhere.

   **Verdict: forced network-ownership migration is REJECTED as a viable
   enforcement mechanism for this resource. Not "needs a prototype spike" —
   a prototype spike is not recommended, because the failure modes above
   are architectural (what a player's own ped's ownership *means*) and
   corroborated by FiveM's own maintainers declining to ship the easier
   version of the same idea, not implementation details a spike would
   resolve differently.**

4. **Conclusion: detection is real and buildable (point 2); the one
   enforcement candidate this document was aware of is not viable (point
   3); nothing else has been identified.** For the Category B half of all
   three mechanics, this codebase can *detect*, after the fact and with
   real but imperfect confidence, that a target's client likely ignored a
   relayed restriction. It cannot *prevent* that non-compliance the way it
   can for an NPC (which it fully owns) or for the K9 player's own actions
   (which the K9's own client has every incentive to execute honestly,
   being the one benefiting from having access at all) — and, per point 3,
   this is not a temporary gap waiting on more engineering effort, it is a
   structural property of what a live player's own ped is in FiveM's
   networking model. This is not unique to `qbx_k9unit` — it is the same
   limitation every comparable PvP restraint/cuff/ragdoll mechanic in the
   ecosystem lives with — but this document will not claim otherwise just
   to close the item.

**The actual ship decision (this is the resolution Revision 3 explicitly
declined to make, made here):**

Ship it — with binding guardrails, not as an unconditional restraint.
Reasoning, weighed against this codebase's own established bar (the same
one applied to block `relayDoorScratch`'s unresolved netId trust gap and
the contraband-search broadcast leak in `phase2_notes/*_security_review.md`
until fixed, and to accept `server/tracking.lua`'s forged-trail gap only
because nothing server-authoritative hinges on it):

- **This is not the same shape of gap as the ones this reviewer has
  previously blocked.** Those were cases where a client-supplied value was
  never independently validated at all (an attacker could point
  `relayDoorScratch` at an arbitrary entity, or leak a search result to
  bystanders) — a cheap, complete fix existed and simply hadn't been
  written. Here, the gap is that a Category B effect's real-world guarantee
  is inherently bounded by physics this resource cannot control (a
  player's own client executing its own input) — no implementation
  discipline closes it, only architecture changes could, and point 3 above
  is why the one available architecture change doesn't work either. Adding
  the guardrails below is this codebase's actual "no shortcuts, no faked
  checks" standard applied *honestly* to a case where the honest answer
  includes a residual gap, not a reason to block shipping outright.
- **The requester already accepted this specific tradeoff, with eyes open,
  when overriding NPC-only scope** — Revision 3's own opening paragraph
  names "the non-cooperating-client limitation inherent to any effect that
  must be applied to a live player's own ped" as one of the tradeoffs
  weighed and accepted, not a detail the requester was unaware of. Blocking
  Category B into a cosmetic-only/deferred posture now, on a technical
  gap that was already disclosed and accepted at the scope-decision level,
  would be re-litigating a decision this document (correctly) says isn't
  this reviewer's call to reopen — the actual open question routed to
  coder-security was the *mechanism*, not the scope, and the mechanism
  question is what points 1–4 above resolve.
- **The blast radius of a successful ignore is bounded, which is the
  precondition that made `server/tracking.lua`'s own similar acceptance
  defensible and is reproduced here as a binding requirement, not an
  assumption:** nothing in this document ties a server-authoritative
  consequence (an arrest completing, evidence being logged, currency,
  items, permissions) to a Category B effect having "succeeded." A target
  who ignores `BiteAndHold`/`forceRagdoll`/`applyDragSpeedLimit` gets an
  unfair moment of mobility in a fight they were already, independently,
  eligible to be targeted in (per item 5's wanted-status gate) — a
  competitive-fairness problem worth taking seriously (hence the detection
  layer), not a data-integrity or capability-grant one. **This must remain
  true as a hard, binding constraint on every future extension of these
  three mechanics** — see the guardrail below.
- **This matches, not merely resembles, the rest of the ecosystem's own
  accepted bar** for the identical mechanic shape (cuffing/ragdoll/restraint
  scripts), which this document's own research already established has no
  better answer anywhere. Shipping nothing here would put this resource
  meaningfully behind ecosystem norms for a decision the requester has
  already made; shipping it honestly labeled matches those norms exactly.

**Binding guardrails — required before any of `BiteAndHold`/
`NonLethalTakedown`/`PropDragging`'s player-target code paths ship, not
optional hardening:**
1. The detection layer specified in point 2 above exists in real, tested
   code in `server/combat.lua` — not merely the config placeholder table.
2. `PropDragging`'s `AttachEntityToEntity` call is re-asserted every tick
   for the duration of an active drag (never one-shot) — see the new
   finding above on `DetachEntity`'s symmetric lack of an ownership gate.
3. **No server-authoritative consequence of any kind may ever be
   conditioned on a Category B effect having been applied successfully to
   a player target** (only on things this server independently verifies —
   proximity, `RequireWantedStatus`, cooldowns). This is new to this
   revision and is the concrete backstop that keeps "detection-plus-log" an
   acceptable ship posture rather than a fig leaf — flagged explicitly for
   whoever designs any future feature that consumes a hold/takedown/drag
   outcome (e.g., a cuffing integration) not to add this coupling later
   without re-opening this item.
4. Every player-facing string describing these three mechanics' effect on
   a player target is worded as best-effort ("attempts to restrain," never
   "the target cannot escape") — Revision 3's recommendation, now a
   ship-blocking requirement rather than a suggestion.
5. `Config.Combat.RequireWantedStatus` stays `true` by default (already
   decided, item 5) and `Config.Combat.NonComplianceDetection.action`
   stays `'log'`/`'notify_staff'` by default, never an auto-punitive value,
   in this resource's own shipped config (confirmed above) — a server
   owner may still wire stronger automated response themselves via
   `OnViolationOverride`.

Routed to coder-backend/coder-architect for implementation (the design
above is concrete enough to build against directly) and to qa-tester/
correctness-overseer for a follow-up pass once `server/combat.lua` exists,
specifically checking guardrails 2 and 3 above, which are the two new,
easy-to-silently-regress requirements this revision adds.

---

## 12.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| **3a — independent, start immediately** | `AgilityAdvanced` | Pure client-local own-body movement — does not touch target/combat logic at all, entirely unaffected by the PvP reversal. Detection method is decided (§12.0 item 3) — remaining work is in-engine tuning. |
| **3b — foundational, depends on `server/partnership.lua` (§12.0 item 7, resolved Revision 5) existing** | `BiteAndHold` | Establishes the shared hold/incapacitate ephemeral state + Recall actor every later combat feature reuses or mirrors, **and** is the first feature to need the Category A/B relay split and player-target eligibility gate from §12.0 items 5/8. Item 7 is resolved (a concrete, scoped `server/partnership.lua` build, no longer an open design question) and item 8 (non-cooperating-client architecture question) is resolved (Revision 4) — both are now real, buildable prerequisites for this sub-phase's *player-target* path rather than blockers awaiting design; the NPC-target path only needs `server/partnership.lua` for its Recall actor. |
| **3c — depends on 3b's target infra** | `NonLethalTakedown` | Reuses whatever target-effect shape 3b establishes, including the relay pattern for a player target; additionally needs the server-computed speed-gate state (§12.5.2) for both NPC and player targets. Same item 8 exposure as 3b for its player-target path. |
| **3d — depends on 3b/3c's target infra** | `PropDragging` | NPC-target dragging is **fully unblocked** (§12.0 item 6's native check suffices there). Player-target dragging is blocked on §12.0 item 6's metadata-check contract actually being built (a small, well-scoped task, not an open unknown) **and** shares item 8's speed-limit-relay exposure for the drag-speed half specifically (the initial attach itself is Category A and unaffected by item 8). |
| **3e — depends on Phase 2's tracking infra AND `server/partnership.lua` (§12.0 item 7, resolved Revision 5)** | `HandlerDownDefense` | Reuses Phase 2's `server/tracking.lua` damage-event log; is a pure consumer of 3b/3c's own target-action paths (§12.0 item 2's UI-convenience reading), so it inherits whatever eligibility/compliance posture those paths land on rather than adding a new one. No longer blocked on an open design fork — blocked on `server/partnership.lua` existing as real, tested code, same shape as item 6's PropDragging prerequisite. |

---

## 12.2 Config schema additions (sketch)

New top-level `Config.Combat` table, in the same style as existing blocks.
**Every numeric value below is an unreviewed placeholder** — flagged
explicitly for a PvP-balance/config-validator pass (`SPEC.md` §9 item 5,
expanded by §12.6 below) before any of this is wired to real code. The
detection-layer knobs are additionally flagged as **pending coder-security's
answer to §12.0 item 8** — they sketch the shape of a detection/response
system, not a working, reviewed one.

```lua
-- ======================================================================
-- PHASE 3 — COMBAT & ADVANCED AGILITY. Every leaf feature independently
-- gated by its own Config.Features flag (already present as placeholders).
-- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
-- PvP-balance/config-validator pass (SPEC.md §9 item 5) -- do not treat any
-- of these as tuned, and do not default-enable the owning feature before
-- that review, per PHASE3_SPEC.md §12.0/§12.6.
-- Phase 3 scope note (PHASE3_SPEC.md §12.0 item 1, DECIDED, Revision 3):
-- targets may be an NPC ped OR a live player, subject to the
-- RequireWantedStatus gate below for player targets. This is a REVERSAL of
-- Revision 2's "NPC-only" decision -- do not re-narrow scope back to
-- NPC-only when reading/implementing this table.
-- BLOCKING NOTE: PHASE3_SPEC.md §12.0 item 8 (non-cooperating-client
-- architecture question) is UNRESOLVED. Do not enable BiteAndHold/
-- NonLethalTakedown/PropDragging's player-target code paths on a live
-- server until coder-security/coder-architect have answered it.
-- ======================================================================
Config.Combat = {
    -- Applies to all three player-targeting mechanics below.
    -- PHASE3_SPEC.md §12.0 item 5.
    RequireWantedStatus       = true,  -- secure-by-default: a K9 may only target a PLAYER who is flagged wanted/suspect. Does not affect NPC targets.
    WantedStatusCheckOverride = nil,   -- function(playerId) -> boolean, OPTIONAL. Expected to be the NORMAL path for a real server -- see §12.0 item 5's fragmentation note on why the default metadata guess below is lower-confidence than PropDragging's.
    -- Default best-effort check if no override is supplied: reads
    -- metadata.wanted / metadata.iswanted if present. LOWER CONFIDENCE than
    -- PropDragging's IsPlayerDownedOverride default -- see §12.0 item 5.

    -- PHASE3_SPEC.md §12.0 item 8 -- DETECTION ONLY, NOT ENFORCEMENT.
    -- Sketches the shape of an abuse-response layer for a target's client
    -- ignoring a relayed Category B effect (see §12.0 item 8 for what that
    -- means). Every value here is a placeholder pending coder-security's
    -- design pass -- do not treat this table as a working solution.
    NonComplianceDetection = {
        enabled                = true,
        positionSampleWindowMs = 500,   -- how often to sample the target's position/velocity during an active hold/ragdoll/drag-limit window
        speedTolerance         = 1.0,   -- m/s of slack over "should be restricted" before flagging -- UNTUNED
        action                 = 'log', -- 'log' | 'notify_staff' -- deliberately NOT 'auto_kick'/'auto_ban': a false-positive from lag/desync should not itself become a punitive action without human review, per this table's own "detection, not enforcement" framing
    },

    BiteAndHold = {
        range            = 2.5,    -- meters, self-initiated trigger range
        maxDurationMs    = 15000,  -- hard timeout if never manually released/recalled -- this IS the "no unbounded trap" guarantee for a non-consensual mechanic, see §12.0 item 4
        cooldownMs       = 20000,  -- per-K9 cooldown between attempts
    },
    NonLethalTakedown = {
        range            = 3.0,
        minTargetSpeed   = 4.0,    -- m/s, SERVER-COMPUTED from position samples -- never a client-claimed "I am sprinting" flag, see §12.5.2. Applies identically whether the target is an NPC or a player, since the server already has authoritative position for both.
        cooldownMs       = 25000,  -- per-K9 cooldown
        targetCooldownMs = 30000,  -- per-target cooldown -- stops repeat takedowns of the same already-downed target by multiple K9s in quick succession, see §12.5.2
        healthFloor      = 100,    -- backstop only, NOT the primary non-lethal mechanism -- primary mechanism is SetEntityCanBeDamaged bracketing, see §12.5.2
    },
    HandlerDownDefense = {
        handlerHealthThreshold  = 100, -- needs review against this server's real max-health/downed-system numbers, see §12.5.3
        triggerRadius           = 15.0, -- max distance from the handler for the partner K9 to receive the defense-mode prompt
        hostileLookbackSeconds  = 10,   -- "hostile" = whoever last damaged the handler within this window, reusing Phase 2's relayDamageEvent log. May now resolve to a player -- subject to the SAME RequireWantedStatus gate as a manually-triggered action, see §12.5.3.
    },
    PropDragging = {
        range               = 2.0,
        dragSpeedMultiplier = 0.6,  -- via SET_PED_MOVE_RATE_OVERRIDE -- must be re-asserted every tick while dragging, this native is NOT a one-shot toggle, see §12.5.4. For a PLAYER target this is a Category B effect relayed to the target's own client -- see §12.0 item 8.
        maxDragDistance     = 30.0, -- safety-valve auto-release distance -- UNRELATED to Config.LeashMaxDistance, do not conflate
        -- IsPlayerDownedOverride: function(playerId) -> boolean.
        -- REQUIRED (not optional-to-consider) before the PLAYER-target drag
        -- path ships -- see §12.0 item 6. NPC-target dragging does not need
        -- this at all (native IsPedDeadOrDying/IsPedRagdoll check suffices).
        IsPlayerDownedOverride = nil,
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

Continuing the trust-model-driven split precedent §11.3 established:

| File | New/extends | Owns |
|---|---|---|
| `client/combat.lua` | **New** | BiteAndHold + NonLethalTakedown self-initiated triggers (the K9 player's own local anim, calls the server callbacks below), PropDragging's client-side trigger (folded in per the original file-count reasoning, unaffected by the PvP reversal — still one file, not two). **New in Revision 3:** this file also registers, unconditionally for EVERY client regardless of whether that player is ever a K9 (see the trust-boundary note below), the target-side handlers `qbx_k9unit:client:applyBiteHold` / `qbx_k9unit:client:forceRagdoll` / `qbx_k9unit:client:applyDragSpeedLimit` (§12.0 item 8's Category B relay targets). |
| `server/combat.lua` | **New** | BiteAndHold + NonLethalTakedown server authority: re-validates access/range/target-scope, resolves player-vs-NPC via `IsPedAPlayer` (never client-claimed), applies §12.0 item 5's `RequireWantedStatus` gate for player targets, computes the server-side speed gate for takedown, applies the health floor plus `SetEntityCanBeDamaged` bracketing (for an NPC target directly; for a player target by relaying the bracket request to that target's own client, per §12.0 item 8), and owns the ephemeral "who's currently held/recalled" state (mirrors `LeashPairs`' shape/hygiene conventions — disconnect cleanup, no unbounded growth). **New in Revision 3:** also owns the `NonComplianceDetection` sampling sketched in §12.2 — flagged as a real candidate for its own file (`server/combat_integrity.lua`) once actually designed by coder-security, since it's materially different in kind from the existing simple speed-gate check (a rolling sample window per active effect, not a one-shot check at request time) — left as coder-architect's call, not mandated here. |
| `client/defense.lua` | **New** | HandlerDownDefense's client-side presentation **only** — per §12.0 item 2's reading, this never applies any state to or takes control of the K9 player's own ped; it only streamlines target selection into the existing `client/combat.lua` action paths, which still require the player's own confirming input and still go through §12.0 item 5's eligibility gate when the pre-selected target is a player. |
| `server/defense.lua` | **New** | Hooks into `server/tracking.lua`'s existing damage-event log (Phase 2); watches for a partnered handler's health crossing the threshold and, per §12.0 item 7 (resolved Revision 5), looks up `server/partnership.lua`'s `Partnerships` table for that handler's citizenid — notifies the partner K9's client if an active partnership resolves to a currently-online K9, silent no-op otherwise. |
| `server/partnership.lua` | **New (§12.0 item 7, Revision 5)** | Owns the "K9 partnership" registry: the `k9_partnerships` DB table (schema modeled on `sql/install.sql`'s `k9_certifications` conventions — see item 7's full design), the in-memory `Partnerships[citizenid] = { partner, isK9, active }` cache with a `RefreshPartnershipCache` mirroring `RefreshCertificationCache`'s pcall/fail-closed discipline, the "Partner Up" consent handshake (mirrors `server/main.lua`'s `PendingLeashRequests` TTL'd single-slot pattern), break/teardown (manual, plus automatic teardown wired alongside every existing `ForceDetachLeashForSource`/`ForceDetachOfficerLeashForSource` call site in `server/certifications.lua`), and a `PlayerLoaded`/`onResourceStart` backfill pair mirroring `certifications.lua`'s own. Gated by a new, dedicated `Config.Features.HandlerPartnership` flag (recommended default `true`), not by `BiteAndHold`'s or `HandlerDownDefense`'s flags. Loaded after `server/cooldowns.lua` (uses `NewCooldown`-style rate limiting on the Partner Up request path, mirroring leash-request's own cooldown) and `server/certifications.lua` (`IsConfiguredK9Model` reuse, and because certifications.lua's revoke/job-change paths need to call into this file's teardown function — load-order note for whoever writes `fxmanifest.lua`'s server_scripts list). |
| `client/movement.lua` | **Extends** | `AgilityAdvanced`'s vault trigger and multi-height capsule-sweep detection (§12.0 item 3) — entirely unaffected by the PvP reversal. |
| `config.lua` | **Extends** | Adds §12.2's `Config.Combat` table verbatim (pending the balance review flagged there). |
| `fxmanifest.lua` | **Extends** | Adds the new client/server files above to their respective script lists. |

**New trust-boundary note this revision must call out explicitly, since it
is a first for this codebase:** every prior client-side gated action in
this resource (leash, radial items, door scratch, certify/revoke) is
initiated by, or applies an effect to, a player who is themselves
attempting to use a K9 feature — the receiving side of every existing
relay is either the K9 player's own client (self-applied effects) or a
consenting partner (leash). The three `qbx_k9unit:client:apply*` handlers
introduced in Revision 3, by contrast, must run on **any connected
player's client**, including a player who has never touched a K9 feature,
holds no certification, and isn't in `Config.Departments` at all — because
item 1's reversal means any eligible player (per item 5's gate) can be a
target. This means the server-side validation in `server/combat.lua` (item
5's eligibility check, proximity, cooldowns, the player-vs-NPC resolution)
is now the **only** thing standing between "any connected player" and
having this code fire against them — there is no symmetrical access-gate on
the *receiving* side the way there is everywhere else in this resource.
Flagged for coder-security as a reason to review `server/combat.lua`'s
validation with the same rigor as `server/certifications.lua`'s grant path,
not less, even though the *target* side has historically been the
lower-scrutiny side of every other mechanic in this codebase.

`server/main.lua`'s own reserved-space comment (*"Reserved for future Phase
2+ small, access-gated K9 actions..."*) remains the wrong home for any of
this, unchanged reasoning from Revision 1/2.

---

## 12.4 — Per-feature detailed spec

### 12.5.1 Bite-and-Hold (`Config.Features.BiteAndHold`)

**Concrete behavior:**
- Trigger: the K9 player selects "Bite & Hold" from the K9 Unit radial
  (self-initiated) while within `Config.Combat.BiteAndHold.range` of an
  eligible target — **NPC ped or live player**, per §12.0 item 1 (Revision
  3 — this is a reversal of Revision 2's NPC-only decision) — passing
  `CanShowK9UI()`.
- Effect: the K9 plays a latch/bite animation oriented at the target; the
  target enters a "held" state lasting up to
  `Config.Combat.BiteAndHold.maxDurationMs`, ending early on (a) the K9
  player selecting "Release," or (b) — per §12.0 item 7, resolved Revision
  5 — the K9's registered partner (per `server/partnership.lua`'s
  `Partnerships` table, checked server-side:
  `Partnerships[recallerCitizenid].active and Partnerships[recallerCitizenid].partner
  == heldK9Citizenid`, never a client-claimed relationship) issuing
  "Recall," whichever comes first. The
  hard `maxDurationMs` cap is, per §12.0 item 4, this mechanic's version of
  the leash's "no unbounded trap" guarantee — it is not merely a balance
  knob, it is load-bearing for this feature's non-consensual design being
  acceptable at all.
- **Against an NPC target:** the K9's own bite-suppression effects
  (`SetBlockingOfNonTemporaryEvents`/`SetPedFleeAttributes`, both confirmed
  real natives) are applied directly against an entity this resource/its
  clients already fully command — no relay problem, unchanged from
  Revision 2's analysis.
- **Against a player target (Revision 3, new):** the restrictive half of
  this effect (suppressing sprint/weapon-fire) is a Category B effect per
  §12.0 item 8 — it is relayed via `qbx_k9unit:client:applyBiteHold` to the
  target's own client, which applies `DisableControlAction` on itself every
  frame for the duration. **§12.0 item 8 is explicitly unresolved as to
  whether a non-cooperating target's client can be prevented (not merely
  detected) from ignoring this** — do not read this feature's acceptance
  criteria as implying the restriction is unconditionally enforced against
  a hostile client. Additionally requires §12.0 item 5's
  `RequireWantedStatus` gate to pass before the request is accepted.
- One hold at a time per K9; a new bite attempt on a target already held by
  someone else is rejected server-side (`already_held`), never silently
  double-applied. This applies identically to player and NPC targets.

**Reality check:** unchanged conclusion from `SPEC.md` §7 — task/animation
plus a control-disable/AI-suppression state, not a literal rigid-body bite.
**Anim status (unchanged from Revision 2):** `creatures@rottweiler@melee@streamed_core@` /
`takedown_from_back` remains the one candidate clip, MEDIUM confidence,
still needing an in-engine preview.

**Event/callback contract (Revision 3, supersedes Revision 2's NPC-only
version):**
- `qbx_k9unit:server:requestBiteHold` (targetNetId: number)
  [client→server, `server/combat.lua`] — re-validates
  `Config.Features.BiteAndHold`, `HasK9Access(source)`, live proximity to
  the resolved entity (never a client-claimed distance), that the entity
  isn't already held, resolves player-vs-NPC via `IsPedAPlayer` (never
  client-claimed), and — **if the target is a player** — §12.0 item 5's
  `RequireWantedStatus` check (reject `not_eligible_target` on failure). On
  success: opens an ephemeral hold-state entry (same shape as Revision 2),
  applies suppression directly for an NPC target, or sends
  `qbx_k9unit:client:applyBiteHold` (holderNetId, expiresAt) to the
  target's own client for a player target, and broadcasts a cosmetic
  "played anim" event to nearby clients.
- `qbx_k9unit:client:applyBiteHold` (holderNetId: number, expiresAt: number)
  [server→client, sent ONLY to the target's own client, new in Revision 3,
  `client/combat.lua`] — applies `DisableControlAction` on sprint/fire
  locally every frame until `expiresAt` or an `endBiteHold`-equivalent
  broadcast arrives. Registered unconditionally on every client — see
  §12.3's trust-boundary note for why this has no access-gate of its own.
- `qbx_k9unit:server:releaseBiteHold` () [client→server] — unchanged from
  Revision 2.
- Server-side timeout past `maxDurationMs` auto-clears the hold — unchanged.
- **Never client-authoritative:** whether a hold is active, when it
  started/expires, whether the target is currently suppressed, AND (new)
  whether a player target is currently eligible are all server state.

**Open questions (remaining):**
- §12.0 item 8 (non-cooperating client) is a real, unresolved gap for this
  feature's player-target path specifically — not listed here as a minor
  open question, it's the blocking item this whole revision routes to
  coder-security/coder-architect.
- Exact bite/attack anim in-engine quality — needs a preview pass.
- Does a held target take any damage over the hold duration? Unchanged
  recommendation from Revision 2 (no — purely a control/mobility
  restriction).
- §12.0 item 7 (handler-partnership link, for the Recall actor) is
  **resolved (Revision 5)** — Recall's authorization now depends on
  `server/partnership.lua` existing as real code, a concrete build
  prerequisite rather than an open design question.

### 12.5.2 Non-lethal takedown (`Config.Features.NonLethalTakedown`)

**Concrete behavior:**
- Trigger: same self-initiated radial pattern as bite-and-hold, requiring
  the target — **NPC ped or live player, per §12.0 item 1 (Revision 3)** —
  to currently be "fleeing," defined as **server-computed speed over the
  last few position samples exceeding
  `Config.Combat.NonLethalTakedown.minTargetSpeed`**, explicitly not a
  client-reported claim. This computation works identically for an NPC or a
  player target — the server has authoritative position for both (a fact
  §12.0 item 8 also leans on for its detection-layer discussion, which is
  the same underlying capability applied to a different purpose).
- Effect: the K9 forces a ragdoll on the target via
  `SET_PED_TO_RAGDOLL_WITH_FALL`; no weapon/melee damage is applied by the
  action itself. The primary non-lethal mechanism remains bracketing the
  forced ragdoll with `SetEntityCanBeDamaged(target, false)` /
  `(target, true)`.
- **Against an NPC target:** applied directly, unchanged from Revision 2.
- **Against a player target (Revision 3, new):** both the forced ragdoll
  and the damage-bracket are Category B effects per §12.0 item 8 — relayed
  via `qbx_k9unit:client:forceRagdoll` (expiresAt) to the target's own
  client, which calls `SetPedToRagdollWithFall` and applies the damage
  bracket on itself. **Same explicit caveat as bite-and-hold: §12.0 item 8
  is unresolved on whether a non-cooperating client's refusal to run this
  handler can be prevented, not just detected.** Additionally requires
  §12.0 item 5's `RequireWantedStatus` gate.

**Reality check:** unchanged from Revision 2 — fully native-only, zero new
asset, no open native questions. `SET_ENTITY_INVINCIBLE` remains explicitly
not used, for the same reason as before (it would fight the ragdoll this
feature needs to look convincing) — this precedent is exactly why §12.0
item 8 refuses to paper over the analogous "does this actually work against
a hostile client" question for the relay case.

**Event/callback contract (Revision 3):**
- `qbx_k9unit:server:requestTakedown` (targetNetId: number)
  [client→server, `server/combat.lua`] — re-validates feature flag, access,
  live proximity, resolves player-vs-NPC via `IsPedAPlayer`, the
  server-computed speed gate (reject `not_fleeing`), and — for a player
  target — §12.0 item 5's eligibility gate (reject `not_eligible_target`).
- `qbx_k9unit:client:forceRagdoll` (expiresAt: number) [server→client, sent
  ONLY to the target's own client, new in Revision 3, `client/combat.lua`]
  — applies the ragdoll + damage bracket locally. Same unconditional-
  registration/no-access-gate note as `applyBiteHold` above.
- Cooldowns (per-K9 and per-target) — unchanged from Revision 2, apply
  identically to player and NPC targets.
- Ordering: unchanged from Revision 2 for an NPC target; for a player
  target, the equivalent ordering (bracket-before-ragdoll,
  bracket-restore-on-release/timeout) must hold on the **target's own
  client**, which the server cannot itself sequence beyond sending the
  relay event with both instructions bundled and trusting a cooperating
  client to honor the ordering — another facet of §12.0 item 8's gap worth
  naming explicitly rather than assuming away.

**Open questions (remaining):**
- §12.0 item 8, same status as for BiteAndHold.
- The "rolling speed history per targetable entity" state — unchanged open
  item from Revision 1/2, now explicitly needed for both NPC and player
  targets rather than NPCs only.
- Should a takedown leave the target in a state some other resource's
  cuff/restraint system can pick up? Unchanged, not decided here.
- §12.0 item 7 does not directly affect this feature.

### 12.5.3 Handler-down defense (`Config.Features.HandlerDownDefense`)

**Settled reading — unchanged from Revision 2, see §12.0 item 2.**

**Concrete behavior (Revision 3 update to the "nearest hostile" resolution
only):**
- Trigger: unchanged — the certified handler's health drops below
  `Config.Combat.HandlerDownDefense.handlerHealthThreshold`, detected via
  Phase 2's `server/tracking.lua` damage-event relay.
- "Nearest hostile": unchanged definition ("whoever the damage-event log
  already attributes as the source of the handler's most recent damage
  within `hostileLookbackSeconds`"). **Revision 3 change:** per §12.0 item
  1's reversal, if the attributed hostile is a player rather than an NPC,
  the pre-selected target is **no longer automatically rejected** the way
  Revision 2 required — it is passed through to the downstream
  `requestBiteHold`/`requestTakedown` validation exactly like any other
  candidate target, which means it is still subject to §12.0 item 5's
  `RequireWantedStatus` gate at that point. **This feature does not get a
  special exemption from the eligibility gate just because the target was
  auto-selected rather than manually chosen** — if the attacking player
  isn't independently flagged wanted, the pre-fill simply fails
  downstream validation the same way a manual attempt against an
  ineligible target would, and the K9 player falls back to the normal
  radial flow.
- **Partnership link — RESOLVED (Revision 5, §12.0 item 7):** "whose K9
  should be notified" is no longer undefined. On a certified handler's
  health crossing `handlerHealthThreshold`, `server/defense.lua` looks up
  that handler's citizenid in `server/partnership.lua`'s `Partnerships`
  table. If an active partnership resolves to a K9 citizenid who is
  currently online, that K9's client is notified per the event contract
  below. **If no active partnership exists — the handler was never
  partnered, or a prior partnership was broken — this is a silent no-op:
  `HandlerDownDefense` simply does not fire for that handler.** This is a
  new, real, disclosed prerequisite this feature did not have under either
  of Revision 2's or the original draft's framing: a "Partner Up" action
  (§12.0 item 7) must have been completed at least once for a given
  handler/K9 pair before `HandlerDownDefense` can ever trigger for them —
  mere K9 certification is no longer sufficient on its own. Flag this
  explicitly in any player-facing documentation/README update once
  implemented (e.g. "requires designating a K9 partner via Partner Up"),
  not left implicit the way an unresolved item 7 previously made it
  impossible to even state precisely.

**Reality check:** unchanged from Revision 2 — this feature needs no new
native capability of its own; it inherits whatever compliance posture
`BiteAndHold`/`NonLethalTakedown` land on for their player-target paths
(§12.0 item 8), since it's a pure consumer of those actions. The one new
dependency this revision adds is non-native: `server/partnership.lua`
existing as real, tested code (§12.0 item 7).

**Event/callback contract:** unchanged from Revision 2, with one addition —
`server/defense.lua`'s damage-threshold handler now calls into
`server/partnership.lua`'s partner-lookup accessor (an exposed, resource-
global function analogous to `HasK9Access`/`IsConfiguredK9Model`'s reuse
pattern, not a re-derived copy of the `Partnerships` table's internals)
before deciding whether to notify anyone.

**Open questions (remaining):**
- §12.0 item 7 is resolved — the remaining work is `server/partnership.lua`
  existing as real code (§12.1's 3e dependency), not a design question.
- `handlerHealthThreshold`'s relationship to the target server's real
  downed/laststand system — unchanged, a config-validator item, not a
  design fork.

### 12.5.4 Prop dragging (`Config.Features.PropDragging`)

**Concrete behavior:**
- Trigger: the K9 selects "Drag" from the radial on a nearby target — **NPC
  ped or live player, per §12.0 item 1 (Revision 3)** — within
  `Config.Combat.PropDragging.range` that is currently "downed."
- **"Downed," for an NPC target: unchanged from Revision 2** — fully
  native, `IsPedDeadOrDying(ped, true)` combined with `IsPedRagdoll`, no
  external dependency.
- **"Downed," for a player target (Revision 3, restored from "forward-
  looking only" to a real requirement): resolved per §12.0 item 6**, NOT
  via the native checks above (see item 6 for why those specifically don't
  answer this question for a player) — via the two-part contract: a default
  check against `metadata.isdead`/`.inlaststand`, with
  `Config.Combat.PropDragging.IsPlayerDownedOverride` as the escape hatch
  for a non-standard EMS/laststand system. This must exist as real, tested
  code before the player-target drag path is enabled — the NPC-target path
  is unaffected and can ship independently of this.
- Effect (once a target is confirmed downed): the K9 attaches near a
  collar/scruff point (`AttachEntityToEntity`) — this initial attach is a
  **Category A effect per §12.0 item 8** (the K9's own client performs it,
  and it takes effect regardless of the target's cooperation, the same way
  existing ecosystem cuffing/carry scripts work) — and moves at
  `Config.Combat.PropDragging.dragSpeedMultiplier` of normal speed via
  `SET_PED_MOVE_RATE_OVERRIDE`. **For a player target, the speed limitation
  specifically is a Category B effect** relayed via
  `qbx_k9unit:client:applyDragSpeedLimit` to the target's own client — this
  is the part of dragging §12.0 item 8's non-cooperating-client gap
  actually applies to; the attach itself is comparatively more robust
  against a hostile client than bite-and-hold/takedown's effects are, and
  that distinction is worth preserving in implementation comments so a
  future reader doesn't conflate the two halves' very different compliance
  properties. Movement continues up to
  `Config.Combat.PropDragging.maxDragDistance` before an automatic release
  — distinct from `Config.LeashMaxDistance`.
  `SET_PED_MOVE_RATE_OVERRIDE` must be looped/re-asserted every tick, per
  `phase2_notes/phase3_combat_natives.md` §4, unchanged.
- Either the K9 or the dragged player can end the drag at will — **this is
  no longer a "future PvP phase" forward note (Revision 2 hedged this as
  "in a future PvP phase, if ever scoped"); it is real, current-phase
  behavior now that item 1 has reversed.** Mirrors the leash's "no consent
  needed to get free" hard rule, applied here to the target ending an
  effect they never consented to entering either (consistent with §12.0
  item 4's framing).

**Reality check:** NPC-target dragging remains fully native-only, zero new
asset, zero open questions (unchanged from Revision 2). Player-target
dragging has exactly one open native-surface gap (§12.0 item 6, now with a
concrete required fix) plus the shared §12.0 item 8 exposure on its
speed-limit half.

**Event/callback contract (Revision 3):**
- `qbx_k9unit:server:requestDrag` (targetNetId: number) [client→server] —
  re-validates feature flag, access, live proximity, resolves player-vs-NPC
  via `IsPedAPlayer`, the appropriate "downed" check for that target type
  (native for NPC, the item 6 contract for a player), and — for a player
  target — §12.0 item 5's `RequireWantedStatus` gate. Opens an ephemeral
  drag-state entry (K9 source ↔ target netId/serverId ↔ anchor point).
- `qbx_k9unit:client:applyDragSpeedLimit` (expiresAt: number) [server→
  client, sent ONLY to the target's own client when the target is a player,
  new in Revision 3, `client/combat.lua`] — applies
  `SET_PED_MOVE_RATE_OVERRIDE` on itself every tick for the duration. No
  NPC-target equivalent needed (the K9's own client / server already
  controls an NPC's move rate directly).
- `qbx_k9unit:server:releaseDrag` () [client→server] — either party ends
  it, zero consent needed either direction, unchanged.
- Distance/expiry safety valve — unchanged, using `maxDragDistance`.

**Open questions (remaining):**
- §12.0 item 6's metadata-check contract must exist in real code before
  the player-target path ships — a concrete, scoped task, not an open
  unknown.
- §12.0 item 8's speed-limit-relay exposure — same unresolved-compliance
  caveat as bite-and-hold/takedown, narrower in practice since the attach
  itself (Category A) is not affected.
- None blocking for Phase 3's NPC-target scope, unchanged from Revision 2.

### 12.5.5 Advanced agility — fence/window vault approximation (`Config.Features.AgilityAdvanced`)

**Unchanged in full from Revision 2 — entirely independent of the PvP
scope question.**

**Concrete behavior:**
- Extends `client/movement.lua`'s existing `AgilityBasicJump` precedent
  (same file, same "self, own body" category) rather than a new file.
- When enabled and the K9 player is moving toward a detected low obstacle
  within `Config.Combat.AgilityAdvanced.maxVaultHeight`, a manual
  radial/keypress trigger fires a scripted "vault" (a short forced-arc
  reposition of the ped over the obstacle via `SetEntityVelocity`,
  optionally layered with `TaskPlayAnim` for a jump-adjacent pose), subject
  to `Config.Combat.AgilityAdvanced.vaultCooldownMs`.
- **Obstacle detection — DECIDED, see §12.0 item 3:** a multi-height
  capsule sweep (`StartShapeTestCapsule`/`GetShapeTestResult`) fired
  forward+upward from the K9's position, measuring the height of whatever
  it hits across several height bands, treating anything under
  `maxVaultHeight` as vaultable. The tagged-prop/zone whitelist option
  remains available as an optional per-server override.
- **Wording correction (unchanged from Revision 2):** there is no generic
  ped "jump task" native — jump is native-locomotion/input-driven
  (`INPUT_JUMP`), not a scriptable task. The actual implementation path is
  either layering the scripted arc on top of the ped's own native jump
  input, or driving the arc via `SetEntityVelocity`/`SetEntityCoords`
  directly from the trigger.

**Reality check:** unchanged from Revision 2 — native-only mechanical
approximation, no real climbing animation exists or is expected to exist.

**Event/callback contract:** unchanged — minimal, entirely client-local.

**Open questions (remaining, tuning/asset-level, not design forks):**
- In-engine tuning of the multi-height sweep's exact height bands, capsule
  radius, and forward distance against real map geometry.
- Exact vault natives/animation pairing for a quadruped skeleton — no
  candidate clip found in either research pass; genuinely unresolved.

---

## 12.6 — Cross-cutting notes carried forward from `SPEC.md` §9

- **§9 item 5 (PvP-balance review)** applies to every numeric value in
  §12.2's `Config.Combat` table, and — per Revision 3 — its scope is
  **re-widened back to cover items 4/5 (non-consensual application,
  target-eligibility)** the way Revision 2 had narrowed it away from,
  since PvP is now in scope. This review should also explicitly weigh in
  on §12.0 item 8's `NonComplianceDetection` placeholder knobs once
  coder-security has actually designed that layer — this document's sketch
  values are not tuned.
- Recommend looping in **config-validator** specifically on
  `Config.Combat`'s numeric knobs, and on the `RequireWantedStatus`/
  `WantedStatusCheckOverride` and `IsPlayerDownedOverride` config surfaces'
  documentation/defaults, before Phase 3 implementation starts.
- Recommend a **coder-security** pass confirming: (a) §12.0 item 5's
  `RequireWantedStatus` gate is actually enforced server-side in every one
  of the three player-targeting mechanics' validation paths (never trusting
  a client's claim that a target is eligible, or that a target is an NPC
  at all — `IsPedAPlayer` resolved server-side, never client-supplied), (b)
  §12.0 item 2's HandlerDownDefense acceptance criteria are met exactly as
  written, and (c) — **answered in Revision 4** — §12.0 item 8: ship
  Category B against a player target under the five binding guardrails item
  8 now specifies (detection layer built, `PropDragging`'s attach
  re-asserted every tick, no server-authoritative consequence ever
  conditioned on a Category B success signal, best-effort-only player-facing
  copy, non-punitive detection defaults); network-ownership migration is
  rejected outright, not deferred to a prototype spike. A coder-security
  pass confirming guardrails 2 and 3 specifically are actually implemented
  (not merely documented) once `server/combat.lua` exists is still
  recommended — same "re-review once the file exists" precedent as the
  door-interaction and contraband-search security reviews in
  `phase2_notes/`.
- §12.0 item 7 (handler-partnership link) is **resolved (Revision 5)** —
  `BiteAndHold`'s Recall actor and `HandlerDownDefense`'s handler-lookup
  now have a concrete mechanism (`server/partnership.lua`'s `Partnerships`
  registry) to build against; what remains is implementation, plus the
  same human sign-off already required for items 1–6, not further design.
- **New for Revision 3:** recommend a **coder-architect** pass on §12.3's
  new trust-boundary note — the `qbx_k9unit:client:apply*` handlers are the
  first client-side surface in this resource that must run generically on
  any connected player regardless of that player's own K9 involvement, and
  deserve the same file-boundary/trust-model scrutiny §11.3 already applies
  elsewhere in this codebase.

## 12.7 — Quick-reference: decisions that must be made before implementation starts

**Resolved this revision (Revision 3) or carried over resolved from
Revision 2, sign-off still needed per the note at the top of §12.0:**
1. **PvP vs. PvE target scope** — **DECIDED (Revision 3, reverses Revision
   2): player-vs-player K9 combat IS IN SCOPE for Phase 3** (§12.0 item 1).
   Not a re-litigation item — the requester made this call explicitly and
   with full awareness of the tradeoffs.
2. ~~HandlerDownDefense's "aggressive state" reading~~ — **DECIDED:
   UI/auto-targeting convenience, not AI takeover** (§12.0 item 2),
   unaffected by the PvP reversal.
3. ~~AgilityAdvanced's obstacle-detection method~~ — **DECIDED:
   multi-height capsule-sweep raycast** (§12.0 item 3), unaffected by the
   PvP reversal.
4. **Non-consensual state application posture** — **RESOLVED (Revision 3):
   combat is correctly a different, non-consensual-by-design category from
   the leash's cooperative/consensual model** — no conflict, but the hard
   duration caps are load-bearing as this mechanic's "no unbounded trap"
   guarantee (§12.0 item 4).
5. **Target-eligibility restriction** — **RESOLVED (Revision 3): config-
   driven, `Config.Combat.RequireWantedStatus` (default `true`) plus a
   `WantedStatusCheckOverride` integration hook** — not left undefined, not
   a same-department-only rule (§12.0 item 5).
6. **PropDragging's "is this player downed" integration point** —
   **RESTORED (Revision 3) to a real, partially blocking requirement for
   the player-target path** (unaffected: NPC-target dragging remains fully
   native and unblocked). A concrete two-part contract (default metadata
   check + `IsPlayerDownedOverride` hook) is specified and must actually be
   built, not just documented, before player-target dragging ships (§12.0
   item 6).
7. **The client-relay/non-cooperating-target-client architecture question —
   RESOLVED (Revision 4, coder-security).** Forced network-ownership
   migration (the one candidate Revision 3 left unevaluated) is
   independently researched against FiveM's actual network-ownership model
   (citizenfx/fivem GitHub issues #3338/#3726, PR #2312) and **rejected as
   not viable** — not deferred to a prototype spike, a sourced "no," for
   both engine-behavior reasons (no shipped native forces this even for the
   easier server-created-entity case) and structural ones (a live player's
   own ped's local-input authority isn't a migratable flag) and an
   anti-cheat one (the fight-for-control pattern itself is indistinguishable
   from a teleport/desync exploit to anti-cheat heuristics). A concrete,
   implementable detection layer is specified (per-effect thresholds,
   sampling cadence, non-punitive default response with an
   `OnViolationOverride` escape hatch). **The ship decision Revision 3
   declined to make is made: Category B ships, under five binding
   guardrails** (detection layer built in real code; `PropDragging`'s
   attach re-asserted every tick, closing a newly-identified
   `DetachEntity` self-release corollary; no server-authoritative
   consequence ever conditioned on a Category B success signal; best-
   effort-only player-facing copy; non-punitive detection defaults) — see
   §12.0 item 8 for the full analysis and reasoning against this codebase's
   own established risk bar.
8. **Handler-partnership link — RESOLVED (Revision 5, coder-architect):
   a new, DB-backed "K9 partnership" registry (Option B), NOT a reuse of
   `LeashPairs` (Option A, rejected outright — not merely deprioritized)**
   (§12.0 item 7). Option A is rejected because its disclosed limitation
   (no defense-mode support for an off-leash K9) isn't a minor residual
   gap the way comparable disclosed gaps elsewhere in this document are —
   it fails `HandlerDownDefense`'s own named primary use case (an off-leash
   foot chase), which is exactly why the original framing needed a link
   "independent of momentary leash state" in the first place. The
   resolution scopes what the dedicated doc's own "Cons" list for Option B
   left open: establishment via a mutually-consented "Partner Up" action
   (mirrors leash's own consent handshake, `PendingLeashRequests`-style),
   a new `k9_partnerships` DB table modeled on `k9_certifications`'
   schema conventions (persisted, not ephemeral — the entire reason this
   registry needs to outlive `LeashPairs`), termination mirroring leash's
   "no unbounded trap, no consent needed to exit" rule plus automatic
   teardown on cert revocation/department change, mutual-consent-only
   authorization (no certifier-grade hierarchy needed, unlike
   certification granting), and a new, dedicated
   `Config.Features.HandlerPartnership` flag and `server/partnership.lua`
   file (§12.3). `BiteAndHold`'s Recall actor and `HandlerDownDefense`'s
   trigger both now consume this registry concretely (§12.5.1/§12.5.3) —
   `HandlerDownDefense` picks up a new, disclosed prerequisite as a
   consequence (a partnership must be established at least once before it
   can ever fire for a given pair). No longer blocks `BiteAndHold`'s 3b or
   `HandlerDownDefense`'s 3e sub-phase as an open design question — both
   are now blocked only on `server/partnership.lua` existing as real,
   tested code, the same concrete-prerequisite shape as item 6's
   `PropDragging` resolution.

**Still genuinely open — needs native/config-tuning verification, not a
design decision:**
9. Native/animation verification still outstanding: the bite/attack anim's
   in-engine visual quality across breeds (§12.5.1) and the vault animation
   for a quadruped skeleton (§12.5.5) — unaffected by the PvP reversal,
   both narrowed but not fully closed.
10. `Config.Combat`'s numeric placeholders, INCLUDING the new
    `NonComplianceDetection` table's placeholder values, need a
    PvP-balance/config-validator pass before any flag in this phase
    defaults to `true` (§12.6) — §12.0 item 8 (Revision 4) specifically
    flags `speedTolerance = 1.0` as too loose for `BiteAndHold`'s
    near-stationary compliant baseline; recommend ~0.5 as a starting point
    for that review, not treated as tuned here.
