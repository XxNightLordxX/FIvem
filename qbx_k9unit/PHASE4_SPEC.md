# qbx_k9unit — Phase 4 Detailed Spec (Inventory, Progression & K9 Wellbeing)

> **HISTORICAL DESIGN DOCUMENT.** This captures the plan and reasoning as of
> the dates named inside it (2026-08-23/24), not a live description of
> today's code. `config.lua` and the actual `.lua` files always win if
> something here disagrees with them. See `DOCS_INDEX.md` for where to look
> for current status instead (`README.md` for technical reference,
> `PROJECT_STATUS.md` for a plain-language snapshot and open decisions).
> Kept in full, unmerged with the other phase specs, because each covers a
> distinct, non-overlapping phase — added by a documentation-consolidation
> pass, 2026-08-25; nothing below this banner was edited.

Status: **planning only — no `.lua` file, `config.lua`, or `SPEC.md` has been
touched to produce this document.** Written while Phase 2 (mid-implementation
by other agents) and Phase 3 (planning-complete, `PHASE3_SPEC.md`, not yet
implemented) both sit ahead of this in the build queue, and while
`Config.Features.HealthStaminaHUD` — the one Phase 4 feature this document
deliberately excludes — is reportedly being implemented live by a concurrent
coder-ui/coder-frontend session. **This document does not cover
`HealthStaminaHUD`, does not touch `client/hud.lua`, `html/`/`web/`, or
either of `phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge` /
`phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge`'s own open items, and does not
modify any file that session might be touching.** It covers exactly the
other nine Phase 4 `Config.Features` flags: `K9Inventory`, `XPProgression`,
`FatigueSystem`, `MoodSystem`, `FearStressSystem`, `DistractionSystem`,
`InjuryLimping`, `K9Medkit`, `ContrabandScreenFX` — all still `false` in the
shipped `config.lua`.

Grounded in a full read of: `SPEC.md` §2 (scope/non-goals), §6.5/§6.6 (the
original one-line Phase 4 descriptions this document replaces with concrete
detail, the same relationship §11 has to §6.3/§6.4 and §12 has to §6.2), §7
(native-only-approximation convention this document extends), §8 (phased
build plan), §9 (open questions, especially item 4 — XP/contraband economy
review), §11 (Phase 2's detailed spec — reused directly for
`relayDamageEvent`/`relayWeaponFire`'s existing log infrastructure and the
`server/search.lua` trust-boundary pattern this document leans on hardest);
`PHASE3_SPEC.md` §12 in full (the second detailed-spec precedent this
document's format mirrors, and the direct source of the `SetPedMoveRateOverride`
re-assertion caveat and the NPC-vs-player scope-fork methodology reused
below); `config.lua`'s already-drafted, unused `Config.XPTiers` table;
`phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` (db-schema's persistence
recommendation for XP, adopted below); `phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge`
and `phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge` (read for cross-reference only —
specifically their `CanShowK9UI()` vs. `IsOwnModelK9()` resolution, which this
document reuses rather than re-litigating, and their identification of
`SetPedMoveRateOverride` as a native other Phase 3/4 systems will also want,
which this document turns into a cross-cutting architectural requirement in
§13.0); and the actual shipped Phase 1/2 files (`config.lua`,
`client/main.lua`, `client/movement.lua`, `client/radial.lua`,
`client/vehicle.lua`, `server/main.lua`, `server/certifications.lua`,
`fxmanifest.lua`) plus `phase2_notes/RESEARCH_ARCHIVE.md#contraband-search` (the
closest existing precedent for a real ox_inventory integration's
security-critical shape, deliberately reused as the template for both
`K9Inventory` and `K9Medkit` below, per this document's own explicit
instruction to do so) — **read, never edited.**

Author: product-agent, 2026-08-23, jlwood17190665@gmail.com.

## Relationship to `SPEC.md` and to this project's document-scale precedent

Same rationale `PHASE3_SPEC.md`'s own header already gives, restated for this
document: `SPEC.md` is long, this agent's toolset has no line-level edit
capability, and reconstructing the whole file from a read-back to append one
section risks silently corrupting reviewed content for zero benefit over a
new file. This document is written to become `SPEC.md` §13 (after §11's
Phase 2 detail and §12's Phase 3 detail) once someone with safe incremental
edit access folds it in — it uses `§13.x` numbering internally for that
reason, and until then should be treated exactly the way `PHASE3_SPEC.md`
treats itself relative to `SPEC.md` §6.2: **authoritative detail that
supersedes `SPEC.md` §6.5/§6.6/§7/§9's existing Phase 4 text for the nine
features in scope here** — reconcile against `SPEC.md` directly if the two
ever drift. `HealthStaminaHUD` is explicitly out of this document's scope
end-to-end (see the Status line above) — whoever eventually folds this into
`SPEC.md` §13 should fold the HUD design notes' own conclusions in alongside
it as a separate subsection, not invent one here.

**Read §13.0 first.** Unlike Phase 2 (whose main structural decision was
sub-phase ordering) and unlike Phase 3 (whose main structural decisions were
four target-scope forks), Phase 4's defining architectural question is
whether five of its nine in-scope features (`FatigueSystem`, `MoodSystem`,
`FearStressSystem`, `DistractionSystem`, `InjuryLimping`) should be five
independent systems or one shared subsystem — and, separately, whether the
resulting client-side movement-speed effects (from wellbeing, from
`XPProgression`, and from Phase 3's already-speced `PropDragging`) can safely
coexist without clobbering each other. Both are decided in §13.0 below,
before anything else in this document assumes an answer.

---

## 13.0 — Cross-cutting architectural decisions (read this first)

### Decision 1: `FatigueSystem`/`MoodSystem`/`FearStressSystem`/`DistractionSystem`/`InjuryLimping` are ONE subsystem, not five

**Decision:** all five ship as one `client/wellbeing.lua` + `server/wellbeing.lua`
file pair, backed by one config table (`Config.Wellbeing`, §13.2) and one
per-citizenid server-side stat store, each `Config.Features.*` flag
independently gating only whether *that stat's own tick logic and
gameplay-facing effects* run — mirroring this codebase's own established
precedent for exactly this shape of decision: `Config.Tracking`'s three trail
types (`ScentTracking`/`BloodTracking`/`GunpowderSniffing`) are three
independently-toggleable `Config.Features` flags that nonetheless share one
`client/tracking.lua`/`server/tracking.lua` pair, one tick/prune loop shape,
and one config table — precisely because building three-to-five near-copies
of the same "decay a number, gate a capability on a threshold, notify the
owning client" plumbing would duplicate logic Phase 2 already proved doesn't
need duplicating.

**Why this is the right call here specifically, not just "because Phase 2 did
it that way":**

- All five are **structurally the same mechanism**: a hidden numeric value
  (0–100 in every case below) that rises or falls based on gameplay triggers
  and, when it crosses a configured threshold, changes what the K9 can do or
  how fast it moves. `SPEC.md` §6.6 itself already describes them in
  parallel, near-identical language ("a tracked... value", "a meter",
  "imposes a... state... until... decays naturally") — the *design* already
  reads as one template applied five times, not five independent designs
  that happen to share vocabulary.
- **Four of the five need the exact same server-side data sources Phase 2
  already built**, not new ones: `MoodSystem` and `InjuryLimping` both react
  to "the K9 took damage" (Phase 2's `relayDamageEvent`/`CEventNetworkEntityDamage`
  relay pattern, §11.4 item 3 — a new *consumer*, not a new native or a new
  detection mechanism); `FearStressSystem` reacts to "gunfire happened
  nearby" (Phase 2's `relayWeaponFire`/`IsPedShooting` relay, §11.4 item 4).
  Building five separate files would mean at least two of them independently
  re-deriving damage-event ingestion that `server/tracking.lua` already
  owns — the same "don't let two divergent copies of the same relay
  infrastructure exist" reasoning `SPEC.md` §11.1 sub-phase 2e already used
  to justify landing `BloodTracking`/`GunpowderSniffing` together.
- **One shared tick loop is cheaper and easier to reason about than five.**
  A single server-side `SetInterval`-style loop (or `CreateThread`/`Wait`
  loop) evaluating all five stats for every online K9-eligible citizenid
  once per `Config.Wellbeing.tickIntervalMs` is one piece of infrastructure
  to get right (disconnect cleanup, no-op when nobody online, per-citizenid
  keying) instead of five, mirroring `server/tracking.lua`'s own single prune
  pass for three trail types rather than three.
- **The gameplay-facing consequences overlap enough that a *composed* effect
  needs to exist somewhere regardless.** A K9 that is simultaneously fatigued
  and injured needs one final movement-speed multiplier, not two independent
  `SetPedMoveRateOverride` calls stepping on each other (this is Decision 2,
  below, and is far easier to get right with one file already holding both
  stats than by having two separate files each partially aware of the
  other's state).

**What this does NOT mean:** the five `Config.Features` flags remain fully
independent per §3's hard requirement — enabling `MoodSystem` alone (with
`FatigueSystem`/`FearStressSystem`/`DistractionSystem`/`InjuryLimping` all
still `false`) must only run Mood's own decay/regen/threshold logic; the
other four stats simply never tick, never get read, and never gate anything,
exactly the same "read at the point of activation, not just declared" test
§3 already applies to every other feature flag in this codebase. One file
owning five independently-gated features is not a new pattern either —
`client/tracking.lua`/`server/tracking.lua` already do this today for three.

**What this means concretely for the rest of this document:** §13.3's file
plan gives `Config.Wellbeing` and the `client/wellbeing.lua`/
`server/wellbeing.lua` pair one entry each, and §13.4.3 documents all five
stats as sub-sections of one feature-group write-up rather than five
separate top-level sections — matching how `SPEC.md` §11.5 documents
`ScentTracking`/`BloodTracking`/`GunpowderSniffing` as three acceptance-
criteria blocks under one detailed-spec section, not three unrelated
features that happen to appear in the same document.

### Decision 2: a single client-side "move-rate composer" is required once Phase 3 + Phase 4 both exist

**Genuine new finding, not present in either `SPEC.md` or `PHASE3_SPEC.md`
in isolation:** by the time Phase 3 and Phase 4 both ship, **at least four
independent features want to call `SetPedMoveRateOverride` on the K9's own
ped**: Phase 3's `PropDragging` (`Config.Combat.PropDragging.dragSpeedMultiplier`,
already flagged in `PHASE3_SPEC.md` §12.5.4 as needing to be re-asserted
every tick, not a one-shot call), and three of this phase's own systems —
`FatigueSystem`'s low-fatigue speed penalty, `InjuryLimping`'s low-leg-health
speed penalty, and `XPProgression`'s tier-based `speedMultiplier` bonus (§6.5:
"applies the tier's `speedMultiplier`... immediately"). `SetPedMoveRateOverride`
is a **single scalar override, last-caller-wins** — it has no concept of
"stack with whatever another script already set." If each of these four
systems calls it independently, on its own tick, with no coordination, the
one that happens to run last on a given frame silently cancels every other
active modifier — a real, easy-to-miss bug class, not a hypothetical one,
given `PHASE3_SPEC.md` §12.5.4 already flags the exact re-assertion-every-tick
behavior that makes "two systems both re-asserting every tick" a guaranteed
collision rather than a rare race.

**Decision:** a single resource-global client function,
`RecomputeK9MoveRate()` (proposed name — no existing naming-slot collision;
follows this codebase's established `PascalCase` verb-first convention per
`README.md#public-api-exports`'s documented rule), owns the **one and
only** call to `SetPedMoveRateOverride` for the K9's own ped. Every system
that wants to influence movement speed — `client/wellbeing.lua` (Fatigue,
Injury), the XP tier effect (wherever it lands, §13.4.1), and Phase 3's
`PropDragging` (`client/combat.lua`, per `PHASE3_SPEC.md` §12.3) — sets its
own named multiplier in a small shared table (e.g.
`K9MoveRateModifiers.fatigue`, `.injury`, `.xpTier`, `.dragging`, each
defaulting to `1.0` when inactive) and calls `RecomputeK9MoveRate()`, which
multiplies every active modifier together and makes the single real native
call. This is a **new, small piece of shared infrastructure this document is
introducing** — it does not exist in any Phase 1–3 file today and belongs in
`client/movement.lua` (the existing home for "own body" locomotion concerns,
per `SPEC.md` §11.3's file-boundary convention) — see §13.3.

**Reality-check caveat, stated honestly per this document's own instruction to
be honest about limits:** this composer prevents *modifiers within this
resource* from clobbering each other. It does **not**, and cannot, prevent
some *other* resource on the same server from independently calling
`SetPedMoveRateOverride` on the same ped and clobbering all of this at once —
that's a genuine, pre-existing FiveM limitation (a single scalar override
native, global per-entity, with no stacking API) no amount of in-resource
coordination can close. Flagged as a known limitation, not treated as solved.

### Decision 3 (methodology note, reused from `PHASE3_SPEC.md`): every "does the client's own claimed stat value matter" question below is answered the same way

Following `PHASE3_SPEC.md` §12.0's own established practice of resolving a
recurring cross-cutting question once instead of five times: every wellbeing
stat, and XP, is **server-authoritative state** — the server, never the
client, owns the real number, exactly the same posture `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema`
already argues for XP specifically ("a modified client claiming 'I'm Elite
tier, give me 10.0m scent range and +15% speed' is a real speedhack/detection-range
exploit if the server ever takes that claim at face value"). But — stated
honestly, not glossed over — **the *movement-speed consequence* of that
authoritative state is still a client-self-applied native effect** (§13.0
Decision 2's `SetPedMoveRateOverride`), the same trust-model category
`PHASE3_SPEC.md` §12.5.5 already accepted for `AgilityAdvanced`'s own-body
locomotion ("a purely client-side... model is not treated as a new gap
requiring a server check, consistent with how Phase 1 already treats native
locomotion as ungated"). A modified K9 client could, in principle, ignore its
own server-pushed fatigue/injury/XP-tier value and never call
`RecomputeK9MoveRate()` at all, giving itself no speed penalty a legitimate
client would suffer. **This is a real, disclosed limitation of the
native-only approach, not a hidden gap** — it is bounded the same way every
other self-applied-effect precedent in this codebase is bounded: it only
ever benefits the cheater's own movement speed (a bounded, self-contained
advantage, the same category as a speedhack a server's separate anti-cheat
is already responsible for catching), and it does **not** extend to any
*server-adjudicated* action — every place a wellbeing stat or XP tier
actually gates a real capability (§13.4's server-authority points, e.g.
`FearStress`'s hesitation state rejecting a Phase 3 combat request
server-side) is enforced from the server's own authoritative value,
independent of whether the client's local movement rendering is honest.
Flagged once here per this decision, not re-derived in every subsection
below.

---

## 13.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| **4a — independent, start immediately** | `ContrabandScreenFX` | Pure client-local cosmetic effect triggered off Phase 2's already-built `SearchZones`/`ContrabandAlerts` result (§13.4.5) — no dependency on anything new in Phase 4 itself, only on Phase 2 infrastructure that (per this session's understanding) is further along than anything else this document touches. Cheapest, cleanest first ticket. |
| **4b — independent, start immediately** | `K9Inventory` | Self-contained ox_inventory stash integration (§13.4.2) with no dependency on wellbeing, XP, or medkit — can be built by a second coder in parallel with 4a/4c. |
| **4c — foundational for 4d/4e/4f** | Wellbeing subsystem skeleton (no `Config.Features` flag of its own — this is the shared `client/wellbeing.lua`/`server/wellbeing.lua` infrastructure from §13.0 Decision 1: the stat store, the shared tick loop, disconnect/prune hygiene, and `RecomputeK9MoveRate()` in `client/movement.lua` from §13.0 Decision 2) | Must land before any of `FatigueSystem`/`MoodSystem`/`FearStressSystem`/`InjuryLimping`/`DistractionSystem` can be meaningfully enabled — mirrors Phase 2's `SearchZones`-before-`ContrabandAlerts` foundational-piece pattern (§11.1 sub-phase 2b), one level up: here the "foundational piece" isn't itself a `Config.Features` flag, it's shared plumbing every wellbeing flag depends on. |
| **4d — depends on 4c** | `FatigueSystem`, `InjuryLimping` | Land together: both are continuously-decaying/regenerating stats whose only gameplay effect is a movement-speed modifier through the shared composer (§13.0 Decision 2) — the two simplest, most mechanically similar wellbeing stats, good first real usage of the 4c skeleton. |
| **4e — depends on 4c** | `MoodSystem`, `FearStressSystem` | Land together: both react to the same class of event (damage/gunfire, reusing Phase 2's relay logs) and both gate a *behavioral* effect (a performance penalty / a command-hesitation state) rather than a pure movement-speed modifier — a meaningfully different effect shape from 4d, worth grouping together for that reason even though all four share the same 4c skeleton. |
| **4f — depends on 4c, and on `InjuryLimping` (4d) existing as a concept** | `DistractionSystem` | The one wellbeing-adjacent feature that isn't a continuously-decaying stat (§13.0 — it's an instant, event-triggered status effect, not a decay/regen value) but still needs the shared stat store to hold its `distractedUntil` timestamp and the shared tick loop to expire it. Needs real ox_inventory item-use registration (meat bait / whistle items) — same class of new ground as `K9Medkit`, see §13.4.3.4's open question on whether to build this alongside `K9Medkit` for that reason. |
| **4g — depends on 4c/4d (`InjuryLimping`'s tracked value)** | `K9Medkit` | Restores both real ped health and the `Injury` stat's tracked value — cannot be meaningfully built before `InjuryLimping`'s stat exists to restore, even though `Config.Features.K9Medkit` is nominally independent. |
| **4h — independent of everything else in this phase** | `XPProgression` | Persistence/award logic (§13.4.1) has zero dependency on the wellbeing subsystem, but its speed-multiplier effect depends on §13.0 Decision 2's move-rate composer existing — sequence after 4c/4d for that reason even though the *award* half could be built any time (including in parallel with 4a–4c). Also depends on Phase 2/3's own action-success events existing as award triggers (§13.4.1) — a cross-phase dependency, not a Phase-4-internal one. |

---

## 13.2 Config schema additions (sketch)

New top-level tables, in the same style as `config.lua`'s existing blocks.
**Every numeric value below is an unreviewed placeholder**, same status as
`Config.XPTiers`/`Config.ContrabandAlertTiers`/`PHASE3_SPEC.md`'s
`Config.Combat` — flagged explicitly for a config-validator/economy-balance
pass (`SPEC.md` §9 item 4, applying to this whole block) before any owning
`Config.Features` flag defaults to `true`.

```lua
-- ======================================================================
-- PHASE 4 — XP AWARDS. Config.XPTiers (thresholds -> speedMultiplier/
-- scentRange effects) already exists in config.lua's Phase 1 block, drafted
-- early and unused until now -- this table is NEW: the per-action award
-- VALUES that accumulate toward those thresholds. Every award value below
-- is an unreviewed placeholder pending economy-balance-agent/config-validator
-- review (SPEC.md §9 item 4), the exact status Config.XPTiers itself already
-- carries.
-- ======================================================================
Config.XP = {
    awards = {
        searchContrabandFound = 25, -- Phase 2 SearchZones result with contrabandFound = true (server/search.lua's existing searchTarget callback, new consumer)
        trackSourceResolved   = 10, -- Phase 2 findTrackableSource returned found = true AND the K9 actually reached the resolved source -- see §13.4.1's open question on how "reached" is detected
        biteHoldSuccess       = 20, -- Phase 3 requestBiteHold success (PHASE3_SPEC.md §12.5.1)
        takedownSuccess       = 30, -- Phase 3 requestTakedown success (PHASE3_SPEC.md §12.5.2)
    },
    -- 'citizenid' (default): XP belongs to the K9 character itself, portable
    -- across a department change. 'job': composite-keyed like
    -- k9_certifications, resets on a department change. OPEN QUESTION, see
    -- phase2_notes/RESEARCH_ARCHIVE.md#xp-schema §6 item 1 -- NOT decided here,
    -- a product call, not a schema call.
    scopePerCitizenidOrJob = 'citizenid',
}

-- ======================================================================
-- PHASE 4 — K9 WELLBEING. Backs FatigueSystem / MoodSystem / FearStressSystem
-- / DistractionSystem / InjuryLimping (§13.0 Decision 1: one shared table,
-- one shared client/wellbeing.lua + server/wellbeing.lua pair, five
-- independently-gated Config.Features flags -- mirrors Config.Tracking's
-- existing precedent). ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS,
-- same status as PHASE3_SPEC.md's Config.Combat -- do not default-enable any
-- owning feature before a config-validator pass.
-- ======================================================================
Config.Wellbeing = {
    tickIntervalMs = 5000, -- ONE shared server-side decay/regen tick for all five stats -- see §13.0 Decision 1 for why this beats five independent timers

    Fatigue = {
        max                     = 100,
        sprintDecayPerTick      = 2.0,  -- applied per tick WHILE server-computed speed indicates sprinting (same rolling-position-sample approach PHASE3_SPEC.md §12.5.2 already specifies for NonLethalTakedown's speed gate -- never a client "I am sprinting" claim)
        idleRegenPerTick        = 1.0,  -- per tick while not sprinting
        restRegenPerTick        = 4.0,  -- per tick while within restRadius of a configured rest point (see restSources below)
        restRadius              = 5.0,
        restSources             = { 'water_bowl' }, -- item names / world-object tags treated as a rest point -- PLACEHOLDER, see §13.4.3.1 open question (Phase 5's deployable kennel isn't required to exist for this multiplier, but interacts with it once it does)
        speedPenaltyThreshold   = 30,   -- fatigue below this value triggers the penalty
        speedPenaltyMultiplier  = 0.85, -- fed into RecomputeK9MoveRate() (§13.0 Decision 2), never a standalone SetPedMoveRateOverride call
    },
    Mood = {
        max                          = 100,
        damageDecayAmount            = 15,  -- flat decrement per logged damage event (reuses Phase 2's relayDamageEvent detection, §13.4.3.2 -- new CONSUMER, not a new native)
        petRegenAmount               = 10,  -- per "Pet K9" ox_target interaction
        petCooldownMs                = 30000, -- per-source cooldown, stops repeat-pet spam
        feedRegenAmount              = 20,  -- per configured food item use
        feedItemName                 = 'k9_treat', -- PLACEHOLDER item name, needs to exist in the target server's ox_inventory items table
        passiveRegenPerTick          = 0.2,
        performancePenaltyThreshold  = 25,
        performancePenaltyMultiplier = 0.9, -- see §13.4.3.2's open question on the exact mechanism this multiplies
    },
    FearStress = {
        max                      = 100,
        gunfireRadius            = 20.0, -- meters -- reuses Phase 2's relayWeaponFire log (server/tracking.lua), new CONSUMER not new native
        gunfireLookbackSeconds   = 15,
        risePerNearbyShotPerTick = 5.0,
        passiveDecayPerTick      = 1.0,
        hesitationThreshold      = 70,
        hesitationDurationMs     = 8000,  -- how long a rejected Phase 3 combat-command attempt stays refused before the K9 may retry, absent a manual calm-down
        calmDownReduceAmount     = 40,    -- radial "Calm Down" command's effect
        calmDownCooldownMs       = 15000,
    },
    Distraction = {
        flashbangImmune     = true, -- SEE §13.4.3.4 REALITY CHECK -- genuinely integration-dependent, NOT a guaranteed native-only outcome, unlike every other line in this table
        meatBaitItemName    = 'k9_meat_bait',      -- PLACEHOLDER
        meatBaitDurationMs  = 6000,
        meatBaitRadius      = 8.0,
        whistleItemName     = 'k9_ultrasonic_whistle', -- PLACEHOLDER
        whistleDurationMs   = 4000,
        whistleRadius       = 15.0,
        perTargetCooldownMs = 20000, -- stops the same K9 being re-distracted back-to-back
    },
    Injury = {
        max                     = 100,
        sprintBlockThreshold    = 30, -- below this, sprint input is blocked (client-local, see reality check)
        jumpBlockThreshold      = 20, -- below this, jump input is blocked
        speedPenaltyMultiplier  = 0.7, -- fed into RecomputeK9MoveRate()
        damageDecayAmount       = 10, -- flat decrement per logged damage event -- independent value from Mood's own damageDecayAmount, same detection source
        passiveRegenPerTick     = 0.1, -- deliberately very slow -- K9Medkit (Config.K9Medkit) is the intended primary recovery path, not natural regen
    },
}

-- ======================================================================
-- PHASE 4 — K9 INVENTORY (ox_inventory stash). See §13.4.2 for the full
-- security-critical integration writeup, mirroring
-- phase2_notes/RESEARCH_ARCHIVE.md#contraband-search's rigor for the same reason
-- that note was written for Phase 2's search feature.
-- ======================================================================
Config.K9Inventory = {
    slots         = 5,
    maxWeight     = 8000,  -- grams-equivalent, same units ox_inventory's own item .weight fields already use (confirmed unit convention: phase2_notes/RESEARCH_ARCHIVE.md#contraband-search §1)
    interactRange = 2.0,
    -- 'department' (default): any player whose job ∈ Config.Departments may
    -- open it, mirroring "shared field equipment" framing.
    -- 'ownerOnly': only the K9 player's own citizenid may open it.
    -- OPEN QUESTION, see §13.4.2 -- not decided here.
    accessScope   = 'department',
    -- nil = no item whitelist (ox_inventory's own slot/weight limits are the
    -- only restriction). Set a Config.SearchContrabandItems-style flat list
    -- to restrict this stash to department-issued gear only -- PLACEHOLDER,
    -- same review status as Config.SearchContrabandItems.
    allowedItems  = nil,
}

-- ======================================================================
-- PHASE 4 — K9 MEDKIT. See §13.4.4.
-- ======================================================================
Config.K9Medkit = {
    itemName      = 'k9_medkit', -- PLACEHOLDER item name
    healthRestore = 50,          -- native health units, restores the K9's REAL ped health (out of GetEntityMaxHealth)
    injuryRestore = 40,          -- restores Config.Wellbeing.Injury's tracked value
    range         = 2.0,
    cooldownMs    = 60000,       -- per-target cooldown, prevents repeated instant-full-heal spam
    -- Job names, in addition to any job ∈ Config.Departments, allowed to use
    -- this item on a K9 -- mirrors PHASE3_SPEC.md §12.0 item 4's resolved
    -- "default metadata/job convention + override hook" pattern for the
    -- identical class of external-EMS-integration problem.
    emsJobs       = { 'ambulance' },
    -- IsMedkitUserAuthorizedOverride: function(usingPlayerServerId) -> boolean,
    -- OPTIONAL. Forward-looking override hook for a server whose EMS/
    -- qualification system isn't captured by a flat job-name list -- left
    -- commented out until a server actually needs it, so it isn't mistaken
    -- for an active default. See §13.4.4.
}

-- ======================================================================
-- PHASE 4 — CONTRABAND SCREEN FX. Purely cosmetic, triggered off Phase 2's
-- ALREADY-BUILT SearchZones/ContrabandAlerts result -- see §13.4.5. Does
-- NOT duplicate Config.ContrabandAlertTiers; only maps a subset of that
-- table's existing `alert` values to a screen effect.
-- ======================================================================
Config.ContrabandScreenFX = {
    triggerTiers = { 'aggressive_bark' }, -- which Config.ContrabandAlertTiers `alert` values also trigger the K9's OWN screen effect
    modifierName = 'drug_wobbly_shroom',  -- CANDIDATE ONLY -- NOT independently verified against a natives-research pass this session, see §13.4.5's reality check
    durationMs   = 8000,
}
```

---

## 13.3 File/module plan (sketch)

Continuing the trust-model-driven split precedent §11.3 established and
`PHASE3_SPEC.md` §12.3 reused (cosmetic/no-real-capability files split from
real-capability-grant files):

| File | New/extends | Owns |
|---|---|---|
| `server/wellbeing.lua` | **New** | The unified stat store (`K9Wellbeing[citizenid] = { fatigue, mood, fearStress, injury, distractedUntil }`), the single shared `Config.Wellbeing.tickIntervalMs` decay/regen loop for all five stats (§13.0 Decision 1), consumption of Phase 2's existing `relayDamageEvent`/`relayWeaponFire` logs (new *readers* of `server/tracking.lua`'s state, not a second copy of that ingestion logic — recommend exposing a small read-only accessor from `server/tracking.lua` if its log isn't already a plain accessible table, rather than reaching into that file's internals directly), the `qbx_k9unit:server:getWellbeingSnapshot` callback (§13.4.3), the server-side halves of `Pet K9`/`Calm Down`/meat-bait/whistle handling, and the server-side gate `server/combat.lua` (Phase 3) must call before honoring a `FearStress`-hesitating K9's bite-hold/takedown request (§13.4.3.3). Ephemeral/in-memory only by default — see §13.4.3's open persistence question — mirroring `server/tracking.lua`'s own precedent for exactly this kind of session-scoped state. |
| `client/wellbeing.lua` | **New** | Receives pushed wellbeing snapshots, sets/clears `K9MoveRateModifiers.fatigue`/`.injury` (§13.0 Decision 2) and calls `RecomputeK9MoveRate()`, enforces the client-local sprint/jump input blocks for low Injury (§13.4.3.5's reality check on why this is client-local, not server-enforced), plays the Distraction status animation/effect, and is the one file every one of the five wellbeing `Config.Features` flags gates its own registration inside (mirroring `client/radial.lua`'s per-item gating convention). |
| `client/movement.lua` | **Extends** | Adds `RecomputeK9MoveRate()` (§13.0 Decision 2) and the shared `K9MoveRateModifiers` table — the "own body, native locomotion" category this file already owns (`AgilityBasicJump`'s suppression thread, the camera toggle) is the correct home for a composer over the K9's own movement natives, not a new file. Also adds the XP tier's own multiplier slot (`K9MoveRateModifiers.xpTier`, written by whatever XP module pushes tier-change notifications, §13.4.1) and reserves the fourth slot (`K9MoveRateModifiers.dragging`) for Phase 3's `PropDragging` to set once that phase lands — this file becomes the one shared seam between Phase 3 and Phase 4's otherwise-independent movement-affecting systems. |
| `server/progression.lua` | **New** | XP award/persistence: the in-memory `K9XP[citizenid]` cache (mirrors `server/certifications.lua`'s `Certifications[citizenid]` cache pattern exactly, per `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` §5's own recommendation), the atomic `k9_progression` UPSERT (schema per that note's §4, not re-derived here), the tier-lookup helper walking `Config.XPTiers` the same way `server/search.lua` walks `Config.ContrabandAlertTiers`, and the award hooks into Phase 2/3's own success paths (§13.4.1). No dedicated client file — the tier-change *effect* is a small addition to `client/movement.lua`'s composer (above), not a whole new client module, per §13.1 sub-phase 4h's note. |
| `client/inventory.lua` / `server/inventory.lua` | **New pair** | `K9Inventory`'s ox_target-triggered stash open, the per-K9 `RegisterStash` call and its access-scope enforcement (§13.4.2). New pair, not folded into an existing file, for the same "real ox_inventory capability grant deserves the certification-file's level of scrutiny" reasoning §11.3 already gave for `client/search.lua`/`server/search.lua`. |
| `client/medkit.lua` / `server/medkit.lua` | **New pair, small** | `K9Medkit`'s ox_inventory useable-item registration and the server-side heal validation (§13.4.4). Calls into `server/wellbeing.lua`'s exposed `RestoreInjury(citizenid, amount)` helper rather than mutating the stat store directly from a second file — same "reuse the existing global, don't re-derive the logic" rule `server/search.lua` already follows for `HasK9Access`. |
| `server/search.lua` | **Extends** (Phase 2 file — referenced here as a plan only; not touched by this document, and not implemented yet as of this pass either) | Adds one small addition for `ContrabandScreenFX`: after computing `alertTier` (§11.4 item 2 step 12), if `Config.Features.ContrabandScreenFX` and `alertTier` is in `Config.ContrabandScreenFX.triggerTiers`, send a client-only (not broadcast) `qbx_k9unit:client:applyContrabandScreenFx` event to the requesting K9's own client alongside the existing return value. Deliberately not a new file — this is a two-line addition to an existing, already-designed callback's success path, the same "small enough to not warrant a new file" judgment call `PHASE3_SPEC.md` §12.3 made for folding `PropDragging` into `client/combat.lua` once its scope narrowed. |
| `client/search.lua` | **Extends** (Phase 2 file, same caveat as above) | Handles `qbx_k9unit:client:applyContrabandScreenFx` — calls `SetTimecycleModifier(Config.ContrabandScreenFX.modifierName)`, waits `durationMs`, clears it. Mirrors `client/vision.lua`'s exit-path discipline (§11.6's "force off on every exit path" rule) — must also clear on resource stop/death/disconnect, not just after the timer. |
| `config.lua` | **Extends** | Adds §13.2's five new tables verbatim (pending the review flagged there). |
| `fxmanifest.lua` | **Extends** | Adds `server/wellbeing.lua`, `client/wellbeing.lua`, `server/progression.lua`, `client/inventory.lua`, `server/inventory.lua`, `client/medkit.lua`, `server/medkit.lua` to their respective script lists. No change needed for the two Phase 2 file "extends" rows above beyond what Phase 2 already added. |

`server/main.lua`'s reserved-space comment ("small, access-gated K9 actions
that need server authority but aren't part of the certification/permission
system itself") is **not** the right home for any of this, for the same
reason `PHASE3_SPEC.md` §12.3 gave for Phase 3's combat/defense state: the
wellbeing stat store and XP cache are each comparable in size to the leash
subsystem that already earned its own real estate in `server/main.lua`, not
a "small" action.

---

## 13.4 — Per-feature detailed spec

### 13.4.1 XP Progression (`Config.Features.XPProgression`)

**Concrete behavior:**
- A configured gameplay action (Phase 2 search success, Phase 2 tracking
  success, Phase 3 bite-hold/takedown success — per `Config.XP.awards`)
  awards a flat XP amount to the acting K9's `citizenid`, applied via the
  atomic UPSERT pattern `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` §4 already
  specifies (`INSERT ... ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp)`),
  updating the in-memory `K9XP[citizenid]` cache **synchronously**, before
  the DB write completes — per that note's §5, correctness of the applied
  gameplay effect depends only on the in-memory update, never on DB
  round-trip latency.
- Crossing a threshold in `Config.XPTiers` immediately (same tick as the
  award, no resource restart) changes two things: (a) the server's own
  authoritative `scentRange` value for that K9, read by `server/tracking.lua`'s
  `findTrackableSource` in place of `Config.Tracking.<Type>.maxRange` — a
  genuine server-side extension of Phase 2's existing callback, and (b) the
  K9's own client is notified of the new tier and sets
  `K9MoveRateModifiers.xpTier` (§13.0 Decision 2) to the tier's
  `speedMultiplier`, then calls `RecomputeK9MoveRate()`.
- On (re)connect / `PlayerLoaded`, the server loads the citizenid's real XP
  total from `k9_progression` (or `0` if no row exists) into `K9XP`, mirroring
  `server/certifications.lua`'s existing cache-backfill pattern for
  certifications — this closes the exact "structural gap" `server/main.lua`'s
  own header already calls out generically for resource-start cache
  backfill, applied here to a second cache.

**Reality check:** fully native-only, zero new asset. The one genuinely
uncertain piece is not a native at all but a **data-model question**, already
raised and left open by `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` (see Open
Questions below) — this is a persistence-design uncertainty, not a
feasibility one.

**Server-authority points:**
- The accumulated XP total, the tier lookup, and the resulting
  `scentRange`/`speedMultiplier` values are **100% server-computed and
  server-cached**. A modified client claiming a higher tier gets nothing —
  `server/tracking.lua`'s `findTrackableSource` reads the server's own
  `K9XP`-derived `scentRange`, never anything the client asserts about its
  own tier, closing exactly the exploit `RESEARCH_ARCHIVE.md#xp-schema` names
  explicitly.
- The `speedMultiplier` consequence is a client-self-applied native effect
  (§13.0 Decision 3) — disclosed, bounded, not treated as solved.

**Event/callback contract sketch:**
- No new client-triggerable event needed for *awarding* XP — awards are
  server-triggered internally, from inside the existing server-side success
  paths of `server/search.lua`, `server/tracking.lua`, and (once built)
  `server/combat.lua`, never from a client-fired "I earned XP" event (there
  is no legitimate reason for a client to ever claim this).
- `qbx_k9unit:client:xpTierChanged` (newTier: table — the matching entry
  from `Config.XPTiers`) [server→client, `client/movement.lua`] — sent to the
  K9's own client only, on any tier crossing (up or down, if a future
  XP-reduction admin path is ever built), so it can update
  `K9MoveRateModifiers.xpTier` and call `RecomputeK9MoveRate()`.
- No callback needed for "what's my current XP/tier" beyond what's pushed by
  the event above — if a future UI wants to *display* the K9's own XP (e.g.
  folded into the HealthStaminaHUD's eventual successor panel, out of this
  document's scope), that's an additive read, not a new authorization
  surface.

**Open questions, explicitly flagged:**
1. **Per-citizenid or per-(citizenid, job) XP scoping** —
   `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` §6 item 1, unresolved: does XP
   survive a department transfer (this document's default,
   `Config.XP.scopePerCitizenidOrJob = 'citizenid'`) or reset with it
   (mirroring `k9_certifications`' job-scoping)? A genuine product call, not
   a schema one — needs sign-off before `server/progression.lua` is written,
   since the schema's primary key shape depends on the answer.
2. **Should a separate append-only `k9_xp_log` exist** for anti-cheat/dispute
   auditing, the way `k9_search_log` exists for search accountability?
   `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` §6 item 2 raises this explicitly
   and does not answer it — not decided here either.
3. **What exactly counts as "the K9 reached the resolved source" for
   `Config.XP.awards.trackSourceResolved`?** Phase 2's `findTrackableSource`
   callback tells the client *where* a source is; it does not currently tell
   the server *whether the K9 subsequently walked there*. Awarding XP the
   moment the callback returns `found = true` (rather than on actual arrival)
   would let a K9 farm XP by repeatedly triggering searches without ever
   completing the search — flagged as a real gap in the award trigger's
   design, not resolved here. A reasonable fix (the K9's client reports
   arrival within some radius of the resolved coordinate, server verifies
   live proximity before awarding, mirroring `server/search.lua`'s own
   proximity-before-anything-else discipline) is sketched but not committed
   to, since it needs a coder to confirm the exact detection shape.
4. **Award values and tier thresholds are unreviewed placeholders** —
   `SPEC.md` §9 item 4, unchanged status, applies to `Config.XP.awards` in
   addition to the already-flagged `Config.XPTiers`.

---

### 13.4.2 K9 Inventory (`Config.Features.K9Inventory`)

**Concrete behavior:**
- On `PlayerLoaded` (or lazily, on first interaction attempt) for a
  K9-eligible citizenid, the server registers a stash via
  `exports.ox_inventory:RegisterStash(id, label, Config.K9Inventory.slots,
  Config.K9Inventory.maxWeight, owner, groups)` with a deterministic,
  per-character id (e.g. `'k9inv-' .. citizenid`) — one stash per K9
  character, not a shared global stash and not one keyed to a "handler's
  active K9 slot" (see the stale-wording note below).
- An ox_target option ("Open K9 Gear") appears on the K9 player's own ped
  within `Config.K9Inventory.interactRange`, visible to whoever
  `Config.K9Inventory.accessScope` permits (§ open question below), gated on
  `CanShowK9UI()` for the interacting player exactly like every other
  gated action in this codebase.
- Selecting it opens the registered stash via the standard ox_target +
  ox_inventory pattern (`exports.ox_inventory:openInventory('stash', stashId)`),
  letting armor/treats/water-bowl/evidence-bag-style items be
  stored/retrieved, subject to `Config.K9Inventory.slots`/`.maxWeight` and,
  if set, `Config.K9Inventory.allowedItems`.

**Correction to `SPEC.md` §6.5's own wording, same category as the HUD design
notes' "controlled/nearby" corrections:** §6.5 describes this stash as
"keyed to the handler's citizenid + active K9 slot" — leftover pre-correction
phrasing from the original NPC-spawn draft (`SPEC.md` §1/§4.5 already
established there is no "handler's active K9 slot" concept at all in the
corrected model). This document's design corrects that to "keyed to the K9
player's own citizenid" — the K9 is the player, so the stash belongs to
their own persistent character, the same way `k9_certifications` and
`k9_progression` are both keyed by the K9's own citizenid, never a
handler's.

**Reality check:** unambiguously native/export-only, zero new asset — ox_inventory
is designed exactly for this (`phase2_notes/RESEARCH_ARCHIVE.md#contraband-search`
already confirms `RegisterStash`'s existence and behavior for the vehicle-trunk
case; the *dynamic, per-player-registered-at-runtime* stash pattern used here
is a different call shape than that note verified, and should get its own
export-signature confirmation pass before implementation, same caveat class
`SPEC.md` §9 item 11 already applies to the vehicle/person search exports —
**not independently verified against a live install or the real
`overextended/ox_inventory` source this session**, flagged honestly rather
than assumed.

**Server-authority points:**
- **Stash access control is a real ox_inventory-enforced capability grant**,
  the same trust category `server/search.lua`'s inventory read already
  established for Phase 2 — the `owner`/`groups` arguments passed at
  `RegisterStash` time are what actually restricts who can open it; the
  ox_target option's client-side visibility (gated on `CanShowK9UI()`) is a
  UX convenience only, exactly the same "client hides the option, server is
  the real gate" split §4.1's security note already establishes for every
  other gated action in this resource. A modified client calling
  `exports.ox_inventory:openInventory('stash', 'k9inv-<anyCitizenid>')`
  directly must be rejected by ox_inventory's own owner/group check, not by
  anything this resource adds on top — this resource's only real
  responsibility is choosing correct, restrictive `owner`/`groups` values at
  registration time, not re-implementing access control itself.
- **Registration itself must not be client-triggerable.** The stash id is
  derived server-side from the K9's own resolved citizenid (never a
  client-supplied string) — a client should never be able to ask the server
  to register or resolve an arbitrary stash id on its behalf.

**Event/callback contract sketch:**
- No new `RegisterNetEvent`/`lib.callback` is strictly required beyond
  ox_inventory's own standard `openInventory` client call and its internal
  server-side validation — this mirrors how Phase 1's `client/vehicle.lua`
  needed no dedicated server round-trip for a client-only action, except
  here the actual security boundary lives *inside* ox_inventory's own code,
  not this resource's.
- If `Config.K9Inventory.allowedItems` is populated (an item whitelist), that
  check is **not** something `RegisterStash`'s own arguments express — ox_inventory
  has no native "restrict this stash to a list of item names" registration
  option (unconfirmed either way this session, flagged as needing
  verification). If no such option exists, enforcing a whitelist would
  require a `registerHook`-style server-side hook on item movement into this
  specific stash (the same `exports.ox_inventory:registerHook('swapItems', ...)`
  mechanism Phase 2's `phase2_notes/RESEARCH_ARCHIVE.md#scent-source-resolution` already
  confirmed exists and works for a different purpose) — rejecting/reversing
  a disallowed item's move into the K9 stash. **This is a real, currently
  unresolved implementation question, not assumed away**: whether
  `allowedItems` is enforceable at all, and how, needs a dedicated
  ox_inventory-hook verification pass before it's treated as a real
  restriction rather than a decorative config field.

**Open questions, explicitly flagged:**
1. **`accessScope`: department-shared or owner-only?** This document defaults
   to `'department'` (any player whose job ∈ `Config.Departments` may open
   it, framing the stash as shared field equipment for that K9, similar to
   how any officer can access a patrol vehicle's trunk) over `'ownerOnly'`
   (private to the K9 player alone, framing it as a personal locker) — a real
   product/security-posture fork, not a formality, since the two readings
   have materially different `RegisterStash` `owner`/`groups` arguments and
   different theft-risk profiles (a shared stash is a place any officer
   could pilfer from; a private one locks out a legitimate handler who
   wants to restock their K9's gear while the K9 player is offline). Flagged
   for an explicit sign-off, default-if-forced stated above, not silently
   picked.
2. **`allowedItems` enforceability** — see the event/callback section above;
   needs an ox_inventory-hook verification pass before this field is treated
   as load-bearing.
3. **Exact `RegisterStash` dynamic-per-player call shape** — not
   independently verified this session against source or a live install,
   same caveat class as `SPEC.md` §9 item 11.
4. **Should opening the K9's own stash require the K9 to be in a
   "safe"/non-leashed/non-combat state** (mirrors `SPEC.md` §9 item 14's
   already-open "should tracking be blocked while leashed-and-constrained"
   question, applied to a new feature)? Not resolved here — a judgment call
   for whoever implements this, not a spec mandate either way.

---

### 13.4.3 K9 Wellbeing — unified subsystem (`FatigueSystem`, `MoodSystem`,
`FearStressSystem`, `DistractionSystem`, `InjuryLimping`)

Per §13.0 Decision 1, these five `Config.Features` flags are documented
together as instances of one mechanism, each with its own concrete-behavior/
reality-check/contract/open-questions treatment below.

#### 13.4.3.1 Fatigue (`Config.Features.FatigueSystem`)

**Concrete behavior:** the server's shared wellbeing tick (`server/wellbeing.lua`,
every `Config.Wellbeing.tickIntervalMs`) decrements a K9's `fatigue` value by
`sprintDecayPerTick` while server-computed recent-position-delta speed
indicates sprinting, and increments it by `idleRegenPerTick` otherwise, or
`restRegenPerTick` while within `restRadius` of a configured rest source.
Below `speedPenaltyThreshold`, the client sets
`K9MoveRateModifiers.fatigue = speedPenaltyMultiplier` and calls
`RecomputeK9MoveRate()` (§13.0 Decision 2); above it, the modifier resets to
`1.0`.

**Reality check:** fully native-only. The "sprinting" detection reuses the
exact server-side rolling-position-sample technique `PHASE3_SPEC.md` §12.5.2
already specifies for `NonLethalTakedown`'s speed gate — not a new
detection method, a second consumer of one already-designed one. No new
asset.

**Server-authority points:** the `fatigue` value and the resulting speed
*classification* (above/below threshold) are server-computed and
server-pushed; the actual `SetPedMoveRateOverride` call is a
client-self-applied effect, per §13.0 Decision 3's disclosed, bounded
limitation.

**Event/callback contract sketch:**
- `qbx_k9unit:client:wellbeingUpdate` (stats: table) [server→client,
  `client/wellbeing.lua`] — one combined push per tick (or on-change with an
  epsilon + heartbeat, mirroring `phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge`
  §5's already-established push-cadence pattern for exactly this class of
  "slowly-changing numbers nobody needs sub-second precision on" problem,
  reused here rather than re-invented) carrying all five wellbeing values
  together — same "one combined message beats a split one" reasoning that
  note already gives (avoids desync between an effect flag and its backing
  number).
- No client-triggerable event needed for Fatigue specifically; it's a pure
  tick-driven consumer.

**Open questions:**
1. Exact rest-source detection mechanism (`Config.Wellbeing.Fatigue.restSources`)
   — an item name check, a world-object proximity check, or both? Not
   resolved here; Phase 5's deployable kennel (not yet speced) will likely
   want to be a rest source too, so whatever mechanism is chosen should be
   extensible rather than hardcoded to "water bowl" alone.
2. Whether `Fatigue` should also gate a Phase 3 combat action (e.g. a fully
   exhausted K9 being unable to attempt `BiteAndHold`) — `SPEC.md` §6.6 only
   describes a speed effect, not a command-gating one, for Fatigue
   specifically (contrast with FearStress below, which explicitly does gate
   commands) — recommend NOT extending scope here without an explicit ask,
   flagged only so it isn't silently assumed either way.

#### 13.4.3.2 Mood (`Config.Features.MoodSystem`)

**Concrete behavior:** `mood` decrements by `damageDecayAmount` on each
logged damage event where the K9 itself is the victim (reusing Phase 2's
`relayDamageEvent` detection — the K9's own client relays "I was the victim"
exactly the way `server/tracking.lua` already does for blood-trail sourcing,
except `server/wellbeing.lua` is a second, independent consumer of that same
relay event, not a change to what `server/tracking.lua` does with it).
Increments via a "Pet K9" ox_target interaction (`petRegenAmount`, subject to
`petCooldownMs`) or a configured food item use (`feedRegenAmount`), and
passively regenerates `passiveRegenPerTick` otherwise. Below
`performancePenaltyThreshold`, a "minor performance penalty"
(`performancePenaltyMultiplier`) applies — see the open question below on
what exactly this multiplies, since `SPEC.md` §6.6's own wording
("performance penalty") is vaguer than Fatigue/Injury's explicit "reduces
speed" language.

**Reality check:** fully native-only for the decay/regen mechanism itself.
The "Pet K9" interaction is a trivial ox_target self/nearby-officer
interaction, no new native risk. The feed interaction reuses the same
ox_inventory useable-item pattern flagged as unconfirmed for `K9Medkit`
below (§13.4.4) — same caveat, not re-derived twice.

**Server-authority points:** `mood` itself is server-tracked, same pattern as
Fatigue. The "Pet K9" interaction's *cooldown* is server-enforced
(`petCooldownMs`) to stop spam-petting for infinite mood regen — this is a
genuine, if low-stakes, rate-limit requirement, the same category
`Config.DoorInteraction.scratchCooldownMs` already established for a
similarly low-stakes repeatable interaction.

**Event/callback contract sketch:**
- `qbx_k9unit:server:petK9` (targetServerId: number) [client→server,
  `server/wellbeing.lua`] — re-validates `Config.Features.MoodSystem`,
  `HasK9Access`-equivalent eligibility for the *interacting* player (open
  question: does petting require the interactor to be in
  `Config.Departments`, or is it open to any nearby player as a lighter-touch
  "anyone can pet a friendly police dog" flavor interaction? Not resolved
  here), live proximity to the target K9's live server-side position (never
  client-claimed), and `petCooldownMs` per `(interactor, target)` pair.
- Feed interaction reuses whatever ox_inventory useable-item mechanism
  `K9Medkit` establishes (§13.4.4) — not a separate contract.
- Included in the same `wellbeingUpdate` push as Fatigue (above).

**Open questions:**
1. **What exactly does the "minor performance penalty" apply to?** `SPEC.md`
   §6.6's own wording is vague relative to Fatigue/Injury's explicit
   "reduces speed" language. Candidate readings: (a) a movement-speed
   multiplier via the same composer as Fatigue/Injury (simplest, most
   consistent with the rest of this subsystem, this document's tentative
   recommendation), or (b) a success-chance penalty on Phase 2 search/track
   rolls or Phase 3 combat rolls (would require plumbing a new parameter
   into already-designed, security-critical server callbacks like
   `searchTarget`/`findTrackableSource`, a materially bigger change than (a)).
   Not decided here — a real design fork, not a naming quibble, flagged
   explicitly per this document's own instruction to surface exactly this
   kind of ambiguity rather than silently pick.
2. Whether petting should require the interactor to hold a job in
   `Config.Departments`, or be open to any nearby player — not resolved.

#### 13.4.3.3 Fear/Stress (`Config.Features.FearStressSystem`)

**Concrete behavior:** `fearStress` rises by `risePerNearbyShotPerTick` per
tick for each weapon-fire event logged in Phase 2's existing
`relayWeaponFire` log within `gunfireRadius` meters and
`gunfireLookbackSeconds` of the K9's live server-side position, and decays
passively otherwise. Above `hesitationThreshold`, the K9 enters a
hesitation state for `hesitationDurationMs` — a real, server-enforced
refusal of "aggressive commands" (interpreted as Phase 3's `BiteAndHold`/
`NonLethalTakedown`/`PropDragging` requests, per `SPEC.md` §6.6's own
"refusal of aggressive commands" wording) — until a "Calm Down" radial
command (`calmDownReduceAmount`, subject to `calmDownCooldownMs`) or natural
decay brings it back below threshold.

**Reality check:** fully native-only — this is the cleanest reuse in the
whole wellbeing subsystem, since it needs zero new detection mechanism at
all: Phase 2's `relayWeaponFire`/`IsPedShooting` relay (already confirmed
real, `phase2_notes/RESEARCH_ARCHIVE.md#tracking`) is queried, not
re-implemented. No new asset.

**Server-authority points — the one wellbeing stat with a *real*, not just
cosmetic, server-enforced gate, worth calling out explicitly per this
document's task-level emphasis on server authority:** unlike Fatigue/Injury's
speed-only consequence (a client-self-applied effect, §13.0 Decision 3),
`FearStress`'s hesitation state must be checked **inside** Phase 3's own
`requestBiteHold`/`requestTakedown`/`requestDrag` server callbacks
(`server/combat.lua`, per `PHASE3_SPEC.md` §12.3) — a modified client that
ignores its own pushed `fearStress` value and fires a bite-hold request
anyway must still be rejected server-side, the same "never trust a client's
claim about its own eligibility" standard `SPEC.md` §4.3 already established
for certification and `PHASE3_SPEC.md` §12.5.1 already extended to combat
target validation. **This is a genuine new cross-file dependency this
document is introducing**: `server/combat.lua` (Phase 3, not yet built) will
need to call a `server/wellbeing.lua`-exposed accessor (e.g.
`IsHesitating(citizenid) -> boolean`) as one more pre-check in its own
validation order, alongside its existing access/proximity/target-type checks
— flagged explicitly here so whoever implements Phase 3's combat file after
Phase 4 exists doesn't have to rediscover this dependency independently, and
so whoever implements Phase 4 first doesn't ship `FearStressSystem` believing
its hesitation state is "done" once the client-side prompt-refusal exists,
when the real security boundary is the server-side reject Phase 3's own
files must add.

**Event/callback contract sketch:**
- `qbx_k9unit:server:calmDownK9` () [client→server, `server/wellbeing.lua`] —
  the K9 player's own self-initiated radial action (self, own body, same
  category as `K9Sit`), re-validates `Config.Features.FearStressSystem`,
  `CanShowK9UI()`, and `calmDownCooldownMs`, reduces `fearStress` by
  `calmDownReduceAmount`.
- `IsHesitating(citizenid) -> boolean` [server resource-global,
  `server/wellbeing.lua`] — the new cross-file accessor described above,
  called from `server/combat.lua` once Phase 3 exists. Naming follows
  `README.md#public-api-exports`'s documented `PascalCase` verb-first
  convention for resource-globals (`IsX` boolean-check form, matching
  `IsOwnModelK9`/`IsConfiguredK9Model`).
- Included in the same `wellbeingUpdate` push as Fatigue/Mood.

**Open questions:**
1. Whether `hesitationDurationMs`'s hard-timeout-then-retry behavior is the
   right shape, versus requiring `calmDownK9` explicitly every time (no
   passive timeout at all) — `SPEC.md` §6.6's own wording ("until the
   handler issues a 'calm down' radial command or the meter decays
   naturally") supports the timeout reading taken here, but the exact
   `hesitationDurationMs` value is an unreviewed placeholder needing tuning,
   same status as every other numeric value in this table.
2. Whether `Config.Departments` membership should gate who can issue "Calm
   Down" on a K9 other than themselves (e.g. a partnered handler calming
   down a K9 mid-panic) versus this being self-only — this document assumes
   self-only (the K9 calms itself, like `K9Sit`) since `SPEC.md` §6.6 says
   "the handler issues a 'calm down' radial command," which under this
   codebase's corrected "handler = partnered officer, not a remote
   controller" model (`SPEC.md` §1) most naturally reads as the K9 player's
   own radial action being prompted/suggested by their human partner
   out-of-band, not a mechanic where a second player's client can force a
   state change on someone else's ped — flagged as an interpretation, not
   asserted as certainly correct, mirroring `PHASE3_SPEC.md` §12.0 item 2's
   own treatment of a similarly ambiguous "handler...command" phrase.

#### 13.4.3.4 Distraction (`Config.Features.DistractionSystem`)

**Concrete behavior — two independent halves, per `SPEC.md` §6.6's own text:**
1. **Flashbang immunity.** The K9 entity does not enter a stunned state from
   a flashbang/stun explosion effect.
2. **Item-triggered distraction.** A thrown "meat bait" item or a used
   "ultrasonic whistle" item, within `meatBaitRadius`/`whistleRadius` of one
   or more K9-model players, sets `distractedUntil = now + duration` for
   each affected K9 (server-side, in the shared stat store, subject to
   `perTargetCooldownMs`), during which the K9 "breaks command briefly" —
   interpreted the same way as `FearStress`'s hesitation state (a rejection
   of Phase 3 combat-command requests server-side) rather than a forced
   animation the K9 player doesn't control, for the identical
   non-possession reason `PHASE3_SPEC.md` §12.0 item 2 already established
   for `HandlerDownDefense`: this resource never takes control of a K9
   player's own ped.

**Reality check — split, since the two halves have genuinely different
feasibility:**
- **Item-triggered distraction: fully native-only**, no new asset beyond
  whatever prop/item icon the meat-bait/whistle items themselves need (an
  ox_inventory item definition, not a scripting blocker) — the detection and
  state-application mechanism is entirely server logic layered on existing
  item-use/throw patterns, no uncertain native involved.
- **Flashbang immunity: genuinely integration-dependent, NOT guaranteed
  native-only** — flagged with the same honesty this codebase already
  applies to the door-lock nudge-open dependency (§11.6). Flashbang/stun
  effects on a live server typically come from a separate, server-specific
  weapon/less-lethal resource (e.g. a flashbang item script), not a single
  vanilla GTA native this resource can intercept generically the way
  `SetSeethrough`/`SetNightvision` are simple global toggles. Whether "immune
  to flashbang stun" is achievable **at all** without cooperation from that
  other resource depends entirely on how it applies its stun effect: if it's
  a `TriggerClientEvent` to nearby players that then calls a local stun
  effect (screen-shake, control-disable), this resource could plausibly
  intercept/no-op that effect only if it knows that other resource's exact
  event name and payload shape — an integration dependency this document
  cannot responsibly guess at, the same reasoning `SPEC.md` §11.6 already
  used to refuse guessing at a specific door-lock resource's API. **This
  document does not commit to a specific mechanism and flags
  `Config.Wellbeing.Distraction.flashbangImmune` as aspirational config
  pending a native/ecosystem-verification pass**, not a guaranteed Phase 4
  deliverable — mirroring exactly how `SPEC.md` §11.6 scoped `nudgeRequiresUnlocked`
  as a hard behavioral guarantee only after confirming what was and wasn't
  achievable, rather than asserting the guarantee first and hoping the
  mechanism exists.

**Server-authority points:**
- **Item-triggered distraction is a real capability with real gameplay
  stakes** (per the task's own explicit flag that this could plausibly be
  used *against* a pursuing K9 by a fleeing suspect, not just by a friendly
  handler) — the server, never the client, determines which K9s are within
  radius of the item-use location (using the K9's own live server-side
  position, never a client-claimed "I got distracted" report), consumes the
  item via ox_inventory server-side (same trust boundary as `K9Medkit`,
  §13.4.4), and applies the resulting state to the affected K9's own
  server-tracked entry. A K9 player cannot self-report "I'm not distracted"
  to dodge the effect, and a hostile player cannot self-report "that K9 is
  distracted" without actually using a real, consumed item near it.
- Flashbang immunity, if achievable at all, is inherently a client-side
  cosmetic suppression (the base stun effect, wherever it comes from, is
  itself typically client-rendered) — same bounded, disclosed limitation
  category as §13.0 Decision 3, not a new one.

**Event/callback contract sketch:**
- `qbx_k9unit:server:applyK9Distraction` (itemType: 'meatBait'|'whistle',
  useCoords is NOT client-supplied — see below) [client→server,
  `server/wellbeing.lua`] — re-validates `Config.Features.DistractionSystem`,
  consumes the configured item via an ox_inventory server export (exact
  export TBD, mirrors `K9Medkit`'s own open question below), resolves
  affected K9s by querying **the using player's own live server-side
  position** (never a client-claimed target coordinate — the same
  "resolve the reporting party's own position, don't trust a claimed
  location" rule `server/tracking.lua`'s `relayDamageEvent`/`relayWeaponFire`
  already established) against every online K9-eligible citizenid's own live
  position within the configured radius, and applies `perTargetCooldownMs`
  per affected K9.
- Included in the same `wellbeingUpdate` push as the other four stats
  (`distractedUntil` as a timestamp field).

**Open questions:**
1. **Flashbang immunity's actual achievability** — see the reality check
   above; genuinely unresolved without an ecosystem-integration pass this
   document cannot perform.
2. **Should `applyK9Distraction` require the using player to hold any
   particular job/permission, or be usable by anyone** (including, per the
   task's own framing, an adversarial fleeing suspect)? `SPEC.md` §6.6's own
   wording doesn't restrict this to a handler's own use — reading it as
   intentionally open (a "trainer's tool" that also works as a
   suspect's countermeasure is a plausible, even thematically appropriate,
   design) rather than assuming a restriction not stated in the source
   text — flagged as an interpretation, not asserted as certainly correct.
3. Same ox_inventory useable-item export uncertainty as `K9Medkit` (§13.4.4)
   — not re-derived twice.

#### 13.4.3.5 Injury/Limping (`Config.Features.InjuryLimping`)

**Concrete behavior:** `injury`'s tracked value (called `Injury` in
`Config.Wellbeing`, matching `SPEC.md` §6.6's "leg health" framing)
decrements by `damageDecayAmount` per logged damage event where the K9 is
the victim (same relay reuse as Mood), and regenerates very slowly
passively (`passiveRegenPerTick`) — `K9Medkit` (§13.4.4) is the intended
primary recovery path, not natural regen, per `Config.Wellbeing.Injury`'s
own comment. Below `sprintBlockThreshold`, sprint input is blocked; below
`jumpBlockThreshold`, jump input is blocked; below either, the composer
(§13.0 Decision 2) applies `speedPenaltyMultiplier`.

**Reality check:** unchanged conclusion from `SPEC.md` §7's existing table —
speed reduction via `SetPedMoveRateOverride` is the primary signal, no
dedicated quadruped limp clipset is assumed to exist as a reusable vanilla
asset, and none is attempted here. The sprint/jump input blocks are
achievable via `DisableControlAction` on the relevant input IDs, the exact
mechanism `client/movement.lua`'s existing `AgilityBasicJump` suppression
thread already uses for a different purpose (confirmed-in-this-codebase
native usage, not a new uncertainty).

**Server-authority points:** the `injury` value itself is server-tracked,
same pattern as every other wellbeing stat. **The sprint/jump input blocks
are client-local, self-applied, and not separately server-enforced** — flagged
explicitly, per §13.0 Decision 3's disclosed limitation, as the same
bounded, self-contained category as the speed penalty: a modified client
ignoring its own low-`injury` value and sprinting anyway gains a bounded,
self-contained movement advantage, not a capability this resource's other
server-authoritative checks (certification, search, combat target
validation) would ever honor differently as a result.

**Event/callback contract sketch:**
- No new client-triggerable event; pure tick-driven consumer of the shared
  `wellbeingUpdate` push, identical shape to Fatigue.
- `RestoreInjury(citizenid, amount)` [server resource-global,
  `server/wellbeing.lua`] — the accessor `server/medkit.lua` calls (§13.4.4),
  clamped to `Config.Wellbeing.Injury.max`.

**Open questions:**
1. Whether Phase 3's `NonLethalTakedown`/`BiteAndHold` targets being NPCs
   only (`PHASE3_SPEC.md` §12.0 item 1) means the K9 itself currently has no
   in-resource combat-originated injury source at all (its only sources are
   Phase 2's generic damage-event relay — falls, being shot, being hit by a
   vehicle, etc., all already covered) — worth confirming this is the
   intended, complete set of injury sources for Phase 4's initial ship, not
   a gap; not resolved here, since it depends on Phase 3's own still-open
   `PHASE3_SPEC.md` §12.0 item 7 (handler-partnership link) landing first.
2. Same rest-source-mechanism ambiguity noted for Fatigue does not apply
   here (Injury has no analogous "rest to heal faster" config field in this
   draft) — flagging only to make explicit that this was a deliberate
   omission, not an oversight: `SPEC.md` §6.6 ties Injury's recovery to
   `K9Medkit` specifically, not to a passive rest mechanic the way Fatigue
   is.

---

### 13.4.4 K9 Medkit (`Config.Features.K9Medkit`)

**Concrete behavior:** a player holding a job in `Config.Departments` or
`Config.K9Medkit.emsJobs` uses the configured `k9_medkit` item on a nearby
K9-model player (an ox_target option "Treat K9," or a direct item-use
targeting the nearest eligible K9 within `range` — exact UX TBD) to restore
`Config.K9Medkit.healthRestore` to the K9's real ped health and
`Config.K9Medkit.injuryRestore` to the wellbeing subsystem's `Injury` value,
subject to `Config.K9Medkit.cooldownMs` per target.

**Reality check:** the *restoration* mechanism itself is native/export-level
achievable, but with an honest confidence caveat this document flags rather
than glosses over, following the same rigor `phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge`
already applied to its own uncertain stamina native: **`SetEntityHealth`
restoring a networked ped's health from server-side script is standard,
widely-used FiveM practice (common in existing QBCore/Qbox EMS revive
scripts) but is NOT independently verified against this codebase's own
established natives-research convention this session** (no equivalent
`phase4_medkit_natives.md` exists yet, unlike Phase 2's every native claim
having a paired `*_natives.md` verification note) — flagged as MEDIUM
confidence, needing the same kind of dedicated verification pass Phase 2
gave every one of its own native claims, not asserted with the same
certainty as, say, `SetSeethrough`/`SetNightvision`. The safer, more
consistent-with-this-codebase's-own-precedent alternative — sending a
`qbx_k9unit:client:applyMedkitHeal` event to the target K9's **own** client
and having it call `SetEntityHealth(PlayerPedId(), ...)` on itself, the same
"client self-applies to its own entity" pattern already used throughout this
document (movement-rate modifiers, sprint/jump blocks) — is recommended over
a direct server-side `SetEntityHealth` call, both for consistency and
because it sidesteps any question of whether a server-issued health change
to a remote-owned ped entity reliably syncs; **this is a recommendation, not
independently confirmed as necessary,** flagged for whoever implements this
to verify one way or the other before committing to either approach.

**Server-authority points — the item-use validation shape deliberately
mirrors `phase2_notes/RESEARCH_ARCHIVE.md#contraband-search`'s established
security-critical pattern, per the task's own explicit direction to treat
this with similar rigor:**
1. Feature-flag and eligibility check first (`Config.Features.K9Medkit`, job
   ∈ `Config.Departments` or `Config.K9Medkit.emsJobs`, or the optional
   `IsMedkitUserAuthorizedOverride` hook) — same "cheapest/most-defensive
   checks first" ordering discipline `RESEARCH_ARCHIVE.md#contraband-search` §3
   establishes.
2. **Live proximity check, mandatory, before any state mutation** — distance
   between the using player's own live server-side position and the
   target K9's own live server-side position must be `<= Config.K9Medkit.range`
   — never a client-claimed distance or a client-claimed target identity.
   This closes the identical "map-wide oracle/effect" risk
   `RESEARCH_ARCHIVE.md#contraband-search` §3 step 8 flags as the single most
   important ordering constraint in that document, applied here to a heal
   effect instead of an inventory read.
3. **Target-type verification** — the resolved target must actually be a
   live, connected, K9-model player (re-derived server-side via
   `GetEntityModel`, per `SPEC.md` §4.5's established "never trust a
   client-reported model" rule) — a client claiming to treat an arbitrary
   entity/player must be rejected if that entity isn't really a K9.
4. **Item consumption is server-authoritative** via ox_inventory's own
   item-use validation (exact export/registration pattern **not
   independently verified this session** — flagged the same way
   `SPEC.md` §9 item 11 flags the search feature's own ox_inventory export
   uncertainty; recommend a dedicated verification pass against
   `overextended/ox_inventory`'s real useable-item registration API, e.g.
   confirming whether items are registered as useable via a
   `data/items.lua` `client.export`/`server.export` field or a
   `CreateUseableItem`-style runtime call, before implementation, mirroring
   `phase2_notes/RESEARCH_ARCHIVE.md#contraband-search`'s own methodology of reading
   the real source rather than assuming a remembered API shape).
5. `Config.K9Medkit.cooldownMs` per target, stamped **before** the heal
   completes (not after), same TOCTOU-safe ordering discipline
   `RESEARCH_ARCHIVE.md#contraband-search` §4 already established for the search
   cooldown.
6. Restoration is clamped to each value's own max (`GetEntityMaxHealth`,
   `Config.Wellbeing.Injury.max`) — never allowed to overheal past 100%.

**Event/callback contract sketch:**
- `qbx_k9unit:server:useK9Medkit` (targetServerId: number) [client→server,
  `server/medkit.lua`] — full validation order per the six steps above; on
  success, calls `RestoreInjury(citizenid, Config.K9Medkit.injuryRestore)`
  (`server/wellbeing.lua`'s exposed accessor, §13.4.3.5) and either directly
  restores health or sends the recommended client-self-apply event (see the
  reality check above — the exact mechanism is the one genuinely open
  implementation decision here).
- `qbx_k9unit:client:applyMedkitHeal` (healthRestore: number) [server→client,
  target K9 only, `client/medkit.lua`] — only exists if the recommended
  client-self-apply approach is taken; calls `SetEntityHealth` on the
  target's own ped locally.

**Open questions, explicitly flagged:**
1. **`SetEntityHealth`'s server-vs-client-applied reliability** — the single
   biggest open implementation question in this section, flagged above,
   needs a native-verification pass before implementation, not assumed.
2. **Exact ox_inventory useable-item registration API** — not independently
   verified this session, same caveat class as `SPEC.md` §9 item 11.
3. **`emsJobs`'s relationship to whatever EMS/qualification system the
   target server actually runs** — this document's default (a flat job-name
   list plus an optional override hook) mirrors `PHASE3_SPEC.md` §12.0 item
   4's resolved pattern for the structurally identical "is this the right
   kind of medical professional" integration question, but is not confirmed
   against any specific server's real EMS resource — same "plausible shape,
   not a confirmed export" caveat that document already gives.
4. Whether treating a K9 should require the K9 player's own consent (mirrors
   this codebase's leash-attach consent precedent, `SPEC.md` §6.1) or be
   administerable without it (mirrors how a human medkit revive typically
   works without the downed player's active consent, since they may be
   incapacitated) — this document leans toward **no consent required**, by
   analogy to human medical treatment on this server rather than the leash
   precedent, but flags this explicitly as a real interpretive choice
   between two established precedents in this same codebase, not an
   obviously correct pick.

---

### 13.4.5 Contraband Screen FX (`Config.Features.ContrabandScreenFX`)

**Concrete behavior:** when Phase 2's already-built `server/search.lua`
`searchTarget` callback (§11.4 item 2) resolves an `alertTier` that appears
in `Config.ContrabandScreenFX.triggerTiers` (e.g. `'aggressive_bark'`, a
large-stash find), and `Config.Features.ContrabandScreenFX` is enabled, the
**requesting K9's own client only** (never a broadcast — see server-authority
points) receives an event applying `SetTimecycleModifier(Config.ContrabandScreenFX.modifierName)`
for `durationMs`, representing the K9 getting a "contact high" from
close-proximity exposure to a large contraband find during a search.

**Reality check:** the mechanism (`SetTimecycleModifier` with an existing
GTA effect) is confirmed native-only per `SPEC.md` §7's original claim — no
custom shader/asset needed. **The exact modifier name is a genuine open
uncertainty this document does not resolve with false confidence**:
`Config.ContrabandScreenFX.modifierName = 'drug_wobbly_shroom'` is a
**candidate only**, chosen because it matches the general "drug-effect-style"
family of timecycle modifiers GTA V's own base game data is understood to
ship (the same family `SPEC.md` §7's original text gestured at without
naming one), but — unlike `SetSeethrough`/`SetNightvision`, which
`phase2_notes/RESEARCH_ARCHIVE.md#vision` and two other independent
passes all confirmed against real source/ecosystem evidence — **no
equivalent verification pass has been done for this specific modifier name**
in this codebase. Flagged explicitly as needing a native/asset-data
verification pass (confirming the exact modifier string exists and produces
the intended visual) before implementation, following the same honesty
standard this document has applied throughout rather than asserting a
specific string with unearned confidence.

**Server-authority points:** this is a purely cosmetic, self-applied
client-side effect on the K9's own screen — the same bounded trust category
as vision toggles (§11.6) and the HUD's own self-vitals display
(`phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge` §6's reasoning: no gameplay
advantage from faking or ignoring a self-only cosmetic). **The one real
server-authority point is upstream of this feature entirely**: the
`alertTier` value this feature keys off is already 100% server-computed by
Phase 2's existing `searchTarget` callback (§11.4 item 2, §11.5's acceptance
criteria) — this feature adds no new trust surface of its own, it only
*reads* an already-trustworthy value and *always* sends the resulting
cosmetic event to the requester only, never broadcasting it — reusing the
exact "requester-only, never target-identifying" broadcast discipline
`SPEC.md` §11.4 item 2 and its final revision already established for the
audible contraband-alert broadcast, applied here to a purely visual, even
more clearly requester-only effect (there is no plausible reason any
bystander would ever need to see this).

**Event/callback contract sketch:**
- `qbx_k9unit:client:applyContrabandScreenFx` (durationMs: number)
  [server→client, requester only, `client/search.lua` extension] — sent
  from inside `server/search.lua`'s existing `searchTarget` success path
  (§13.3's file plan), never a separate client-triggerable request (there is
  no legitimate reason a client would need to ask for this effect on
  demand — it only ever follows a real, already-validated search result).
- `client/search.lua`'s handler calls `SetTimecycleModifier`, waits
  `durationMs`, then explicitly clears it (`ClearTimecycleModifier`) — and,
  per §11.6's already-established discipline for exactly this class of
  "global local-render toggle with no automatic reset," must also force-clear
  it on resource stop/disconnect/death, mirroring `client/vision.lua`'s own
  required exit-path handling rather than assuming the timer alone is
  sufficient.

**Open questions, explicitly flagged:**
1. **Exact `SetTimecycleModifier` string** — genuinely unverified, see the
   reality check above.
2. **Which `Config.ContrabandAlertTiers` tier(s) should trigger this** — this
   document defaults to only the most severe existing tier
   (`'aggressive_bark'`), leaving the "clean" and "whine" tiers unaffected,
   but this is a judgment call about severity mapping, not dictated by
   `SPEC.md` §6.6's own text, which doesn't specify a threshold at all.
3. Whether this effect should also apply to a K9's *own* ingestion during
   `K9Inventory` interactions with contraband-adjacent items (out of scope
   for this document's read of §6.6, which frames it specifically around
   search results — flagged only so it isn't silently assumed to extend
   further than specified).

---

## 13.5 Cross-cutting notes carried forward to `SPEC.md` §9

- **`SPEC.md` §9 item 4** (XP tiers, contraband thresholds needing
  economy-balance-agent review) now also covers every numeric value in
  `Config.XP.awards`, `Config.Wellbeing`, `Config.K9Inventory`,
  `Config.K9Medkit`, and `Config.ContrabandScreenFX` introduced in §13.2 —
  the scope of that existing open item widens, it doesn't get a duplicate.
- **New cross-phase dependency, not previously documented anywhere**: Phase
  3's `server/combat.lua` (not yet built) will need to call
  `server/wellbeing.lua`'s `IsHesitating(citizenid)` accessor (§13.4.3.3) as
  part of its own request-validation order once both phases exist —
  whichever phase is implemented second should confirm this dependency
  against the other phase's actual shipped code before assuming the sketched
  contract still matches.
- **New cross-phase shared-infrastructure requirement**: `client/movement.lua`'s
  `RecomputeK9MoveRate()` composer (§13.0 Decision 2) must exist before
  Phase 3's `PropDragging` and any of this phase's speed-affecting features
  ship together on a live server, regardless of which phase's code lands
  first chronologically — whichever phase's coder gets there first should
  build the composer as shared infrastructure rather than a single-purpose
  helper scoped only to their own feature.
- **Every ox_inventory export/registration pattern this document relies on
  beyond what `phase2_notes/RESEARCH_ARCHIVE.md#contraband-search` already
  confirmed** (dynamic per-player `RegisterStash`, useable-item registration,
  any item-whitelist enforcement hook) **is flagged as unverified against
  real ox_inventory source or a live install this session** — recommend a
  dedicated verification pass (mirroring that note's own methodology of
  reading the real `overextended/ox_inventory` source directly) before
  `client/inventory.lua`/`server/inventory.lua`/`client/medkit.lua`/
  `server/medkit.lua` implementation starts, the same way that note was
  written specifically to de-risk `server/search.lua` before its
  implementation began.
- **Flashbang immunity's genuine integration dependency** (§13.4.3.4) joins
  door-lock nudge-open (`SPEC.md` §9 item 12) as the second Phase 2+ feature
  whose native-only feasibility is conditioned on a specific, unconfirmed
  third-party resource's behavior on the target server — recommend tracking
  both under one "external integration dependencies" heading if `SPEC.md` is
  ever restructured, rather than as two unrelated one-off flags.

---

## 13.6 — Quick-reference: decisions that must be made before implementation starts

1. **§13.0 Decision 1** (unify five wellbeing flags into one subsystem) and
   **Decision 2** (single move-rate composer) — both **decided** by this
   document, following direct precedent already established in this
   codebase (`Config.Tracking`'s three-types-one-file-pair shape); still
   worth a one-line human sign-off before implementation, same status
   `PHASE3_SPEC.md` §12.0 items 1–3 carry for their own "decided, sign-off
   still needed" items.
2. **XP scoping: per-citizenid or per-(citizenid, job)?** — genuinely open,
   `phase2_notes/RESEARCH_ARCHIVE.md#xp-schema` §6 item 1, blocks
   `server/progression.lua`'s schema.
3. **`K9Inventory.accessScope`: department-shared or owner-only?** — genuinely
   open, §13.4.2 item 1, blocks the `RegisterStash` `owner`/`groups`
   arguments.
4. **Mood's "performance penalty" mechanism** — genuinely open, §13.4.3.2
   item 1, a real design fork between a simple speed multiplier and a
   heavier change to already-designed security-critical Phase 2/3 callbacks.
5. **Flashbang immunity's actual achievability** — genuinely open, §13.4.3.4,
   an unconfirmed third-party integration dependency this document cannot
   resolve.
6. **`SetEntityHealth`'s server-vs-client-applied reliability for
   `K9Medkit`** — genuinely open, §13.4.4 item 1, needs a native-verification
   pass this document could not perform.
7. **ox_inventory export/registration signatures** for dynamic per-player
   stashes and useable items — genuinely open, needs a verification pass
   against real source, same methodology as
   `phase2_notes/RESEARCH_ARCHIVE.md#contraband-search`.
8. **Every numeric placeholder in §13.2** needs a config-validator/
   economy-balance-agent pass before any of the nine `Config.Features` flags
   in this document's scope defaults to `true` on a live server — unchanged
   in kind from every prior phase's identical requirement.
