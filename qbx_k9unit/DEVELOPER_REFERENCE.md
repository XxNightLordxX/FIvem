# qbx_k9unit — Developer Reference

**Consolidated 2026-08-25.** This one file replaces fifteen previously
separate documents: `SPEC.md`, `PHASE3_SPEC.md`, `PHASE4_SPEC.md`,
`PHASE5_SPEC.md`, `REFACTOR_ROADMAP.md`, `phase2_notes/RESEARCH_ARCHIVE.md`,
`PROJECT_STATUS.md`, `WATCHDOG_LOG.md`, `FEATURE_IDEAS.md`, `DOCS_INDEX.md`,
`locales/README.md`, `tests/README.md`, and `shared/compat/README.md` (all
deleted — their content lives below or was cut as superseded decision
history), plus `sql/rollback/README.md` and `sql/README.md` (folded into
`OPERATOR_RUNBOOK.md` instead, since removal/day-to-day-operation
instructions belong with the other operator-facing material, not here).

**Section numbers below are preserved from the source documents on
purpose.** Hundreds of code comments across this resource cite a section by
number (e.g. `SPEC.md §4.2`, `PHASE3_SPEC.md §12.5.1`, `PHASE4_SPEC.md
§13.4.2`, `REFACTOR_ROADMAP.md item 1`, `RESEARCH_ARCHIVE.md#tracking`,
`FEATURE_IDEAS.md Part A §2`). Every one of those numbers/anchors still
means the same thing here — only the filename changed, to `DEVELOPER_REFERENCE.md`.
If you're trying to resolve a citation from a code comment, find its
section number below; it hasn't moved.

**What was cut, and why:** these source documents totaled roughly 5,700
lines, most of it decision *history* — rejected alternatives, corrections to
corrections, revision-by-revision narration, "verified again, still true"
audit trails. None of that is reproduced here. What's kept is: a live
constraint the code still depends on, a question that's genuinely still
open, and — where a rejected idea would obviously get re-proposed by
someone who didn't know it had already been tried — a one-line note saying
so. If something below disagrees with `config.lua` or the actual `.lua`
files, **the code wins**; nothing here is a second copy of the code's
current behavior.

**Where to look for what:**

| You want... | Read |
|---|---|
| Why this resource is designed the way it is (goals, hard requirements, certification model) | §1–§10 below |
| The detailed per-feature spec for a phase (config shape, event contracts, open items) | §11 (Phase 2), §12 (Phase 3), §13 (Phase 4), §14 (Phase 5) |
| Confirmed native behavior / security review findings other code relies on | §15 |
| Known technical debt and what's already been fixed | §16 |
| Current live/off status of flags and operator decisions still needed | §17 (superseded day-to-day by `OPERATOR_RUNBOOK.md` and `README.md` — this section is the historical reasoning) |
| Not-yet-built feature ideas | §18 |
| How the locale/translation system works | §19 |
| How the automated test suite works | §20 |
| How the `shared/compat` resource-detection layer works | §21 |
| Install steps, current config reference, exports | `README.md` |
| Day-to-day operation, uninstalling | `OPERATOR_RUNBOOK.md` |
| How to play a K9 | `PLAYER_GUIDE.md` |
| What shipped and when | `CHANGELOG.md` |
| Features still being actively built | `K9_IDEAS.md` |

---

## 1. Goal

The K9 is a **player's own persistent character** — someone creates their
character as a dog ped from the start via the server's own
character-creation system (outside this resource's scope; this resource
never spawns, despawns, or possesses a ped on anyone's behalf). That
K9-playing player is **hired** into an eligible department through the
server's normal job-hiring flow (also outside this resource's scope), then a
qualifying officer **certifies** them (§4), granting access to K9-specific
mechanics for as long as they hold both the job and an active certification.
**Getting fired from the department automatically revokes the certification**
(§4.4).

Every subsystem is independently toggleable, and access control is a real,
persistent, server-authoritative permission system, not a hardcoded
job/rank check.

**"Handler" in this document means a partnered human officer** working
alongside the K9 player (leash-together, handler-down defense — §4.4, §9),
never someone who spawns, selects, or remote-controls the K9. The K9 player
controls themselves directly, like any other player character, at all times.

---

## 2. Scope

### In scope (this resource, across all phases)
- Qbox-only (qbx_core, ox_lib, ox_target, ox_inventory, oxmysql). No ESX.
- Multi-department, certification-based access control (hard requirement 2).
- Config-driven ped roster, feature toggles, department list, rank thresholds
  (hard requirement 1).
- K9 model detection, quadruped movement, leash mechanics, radial self-action
  menu, vehicle load/unload, bark sounds (Phase 1).
- Scent/blood/water/gunpowder tracking, search zones, contraband alert tiers,
  thermal/night vision (Phase 2).
- Bite-and-hold, non-lethal takedown, handler-down defense mode, prop
  dragging, agility mode (Phase 3).
- ox_inventory K9 stash, XP/progression, vitality HUD, K9 medkit, contraband
  screen effect (Phase 4).
- Advanced bark radial, proximity audio attenuation, prop attachments, fetch
  mechanic, deployable kennel, K9 camera feed R&D spike (Phase 5).

### Explicit non-goals
- **ESX support.** Qbox/QBCore data model only.
- **True live-video PiP camera feed** of the dog's point of view. Concluded
  infeasible without new native support — see §7/§15 (`#phase-5-research`).
  Do not re-propose without a real engine-level capability landing in FiveM
  first; only a feasibility spike was ever committed, and it already ran.
- **Permanent scar overlay textures.** Needs a custom ped
  texture/decoration-asset pipeline outside plain scripting.
- **Bespoke mocap animation sets** for bite-hold, agility, and limp gaits.
  Approximated with native anim dictionaries/task natives (§7); true custom
  animation is an art-asset request, not a coding one.
- **AI-controlled/automatic patrol K9s, or any "one active K9 per handler" /
  spawn-despawn concept.** The K9 is always a real player's own persistent
  character.
- **Integration with a specific third-party bodycam/dashcam resource.**
  Exports/events are exposed so integration is *possible*; no particular
  external resource is assumed to exist.

---

## 3. Hard requirement 1 — config-driven, in detail

Every feature area maps to one boolean in `Config.Features`, read at the
point where that feature activates (event registration, thread start, menu
item visibility, command registration) — never cached once at resource
start and then ignored. Setting `Config.Features.X = false` and restarting
must remove that feature's client-visible surface **and** make its
server-side handlers a no-op — a disabled feature must not be triggerable by
a modified client. `Config.Peds` is a recognized K9 **model list**, never a
spawn roster; adding a model needs zero `.lua` changes outside config, and
default ships exactly `a_c_shepherd`, `a_c_rottweiler`, `a_c_huskie`,
`a_c_chop`.

---

## 4. Hard requirement 2 — multi-department certification access

### 4.1 Design decision

**Access rule:** `player.job.name ∈ Config.Departments` **AND** the player
holds an **active** K9 certification for that job, checked **server-side**
on every gated action — never cached client-side as a one-time pass.

**Exception:** K9 vehicle entry/exit (`client/vehicle.lua`) is deliberately
**client-only**, no server-side re-check — it grants no real capability
(only freezes/hides/repositions the acting player's own ped), so a modified
client gains nothing here it couldn't already get by calling the same
client-only natives on itself. Revisit if a later feature ever conditions
something server-authoritative on vehicle state.

**Rank auto-bypass:** by default, **no rank auto-bypasses certification**,
including a department's own chief/boss. `autoAccessGrade` is an optional
per-department config field for a boss-rank bypass, defaulting to `nil`
(disabled).

**Self-certification:** `Config.AllowSelfCertification` (default `true`)
lets a certifier-grade+ officer grant/revoke their own certification, to
bootstrap a fresh server. Settable `false` to force a second-party grant.

### 4.2 Certifier eligibility

A player may grant or revoke a K9 certification for a target if:
1. Granter's `job.name` is a key in `Config.Departments`, AND
2. Granter's `job.grade.level >= Config.Departments[job].certifierGrade` **OR**
   `job.isboss == true`, AND
3. Target's `job.name` is a key in `Config.Departments` (any listed
   department, not necessarily the granter's own — cross-department
   certifying is intentional; see §9 item 2 if this should be narrowed).
4. Granter and target are within **5 meters** at the moment the
   grant/revoke is processed **server-side** (live entity coords, never a
   client "I'm near them" claim) — applies to both the ox_target flow and
   the slash-command flow.
5. Target's *current* ped model — read server-side via `GetEntityModel`,
   never client-reported — hashes to a `Config.Peds` entry. Grant-only; a
   revoke is always possible regardless of the target's current model
   (including via §4.4's automatic path).

### 4.3 Certification data model

**Dedicated DB table is the source of truth**, not qbx_core metadata alone
— revocation must work while the target is offline, an audit trail is a de
facto requirement for a permission this consequential, and a table
trivially supports "list all certified handlers in department X." A
read-only boolean mirror (`metadata.k9certified`) is written for
**client-side HUD display only** — never read by a server-side check: the
client can see its own cert flag, the server never trusts it.

Schema (see `sql/install.sql` for the exact, current DDL):

```sql
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`              INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`       VARCHAR(50)  NOT NULL,
  `job`             VARCHAR(50)  NOT NULL,
  `granted_by`      VARCHAR(50)  NOT NULL,
  `granted_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`      VARCHAR(50)  DEFAULT NULL,  -- or a sentinel like 'system:job_change' for §4.4 auto-revokes
  `revoked_at`      DATETIME     DEFAULT NULL,
  `active`          TINYINT(1)   NOT NULL DEFAULT 1,
  `active_cert_key` VARCHAR(105) GENERATED ALWAYS AS (
    CASE WHEN `active` = 1 THEN CONCAT(`citizenid`, '::', `job`) ELSE NULL END
  ) VIRTUAL,
  PRIMARY KEY (`id`),
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),
  KEY `idx_job_active` (`job`, `active`),
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**Invariant: at most one `active = 1` row per `(citizenid, job)`**, enforced
at both layers — app-level (grant pre-checks and no-ops if an active row
exists; revoke sets `active = 0` rather than deleting) and DB-level (the
`uq_one_active_cert_per_job` unique index on the generated column closes the
check-then-act race between two near-simultaneous grants; MySQL treats every
`NULL` as distinct, so revoked rows never collide). **Treat a duplicate-key
error (1062) on the grant INSERT as the same "already certified" no-op, not
an unhandled error.**

**Flow summary:**

| Step | Actor | Mechanism |
|---|---|---|
| Grant | Certifier via ox_target or `/k9certify [id]` | eligibility check (§4.2) → INSERT → cache update → notify both |
| Revoke, online | Certifier via ox_target or `/k9decertify [id]` | eligibility check → UPDATE → cache update → notify |
| Revoke, offline | `/k9decertifyoffline [citizenid] [job]` (command-only — no numeric server id exists for a disconnected target) | UPDATE by citizenid+job, no proximity/model check possible |
| Revoke, automatic | System, on leaving the department | `QBCore:Server:OnJobUpdate` (§4.4) |
| Check | Any gated action | `hasK9Access` callback: job ∈ Departments AND (cache OR autoAccessGrade) |
| Display only | Client HUD | own `metadata.k9certified` mirror, never used for authorization |

**Security note:** every mechanism above must re-verify server-side,
independent of what the requesting client claims about its own job, rank,
proximity, or ped model. Client-side visibility is a UX convenience only.

### 4.4 Automatic revocation on leaving the department

A certification is only valid while the holder is actually employed by an
eligible department — leaving (including being fired) **automatically
revokes it**, and it does not silently return on rehire without
re-certification.

**Mechanism:** `AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job) ... end)`
— a real, non-networked qbx_core server event covering both legacy-QBCore
and Qbox-native hire/fire flows.
([Qbox server events docs](https://docs.qbox.re/resources/qbx_core/events/server))

**Handler logic:** resolve citizenid → look up the cached *previous* job →
if it held an active cert for that job and the new `job.name` differs, run
the standard revoke with `revoked_by = 'system:job_change'` → refresh cache →
notify if online.

**Load-bearing consequences:** a cert is **job-scoped** (leaving and
rejoining later does not restore it — a fresh grant is required); a
**grade change within the same department must never revoke** (guard on
`job.name` changing, not on `OnJobUpdate` firing at all, or every promotion
silently strips certifications); the automatic path is server-triggered
only, with no client-callable equivalent.

### 4.5 Recognizing a K9 character

No spawn step exists to hang model detection off:

- **Authoritative (server):** wherever the model matters for a security or
  role-assignment decision — §4.2 item 5's certify-eligibility check, and
  leash role-assignment (§6.1) — the server reads it live via
  `GetEntityModel(GetPlayerPed(targetServerId))` against `Config.Peds`
  hashes. Never trust a client-reported model. One shared helper
  (`IsConfiguredK9Model`) backs every such check.
- **Convenience (client):** the client may check its own model purely to
  decide whether to show K9-specific UI. Display optimization only — a
  modified client showing itself the menu still gets rejected server-side.
- **No new persistent storage needed** — the ped model is already part of
  the player's persistent character. If a server's separate
  appearance/customization resource can change the base model mid-session,
  the live check could theoretically race a swap — see §9 item 8, not
  addressed speculatively here.

---

## 5. Config schema (concrete shape)

Phase 1's original schema is illustrated below; Phase 2–5 additions are
specified next to the section that scoped them (§11.2, §12.2, §13.2, §14.2).
**`config.lua` itself, not this section, is the source of truth for the
complete current schema and values** — this is a design-intent snapshot,
not a duplicate maintained in sync.

```lua
Config = {}

Config.Features = {
    -- Phase 1
    LeashMechanics       = true,
    RadialMenu           = true,
    VehicleEntryExit     = true,
    BasicBarkSounds      = true,
    AgilityBasicJump     = true,

    -- Phase 2 (tracking & vision)
    ScentTracking = false, BloodTracking = false, WaterTrackingDecay = false,
    GunpowderSniffing = false, SearchZones = false, ContrabandAlerts = false,
    ThermalVision = false, NightVision = false, DoorInteraction = false,

    -- Phase 3 (combat & action)
    BiteAndHold = false, NonLethalTakedown = false, HandlerDownDefense = false,
    PropDragging = false, AgilityAdvanced = false,

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory = false, XPProgression = false, HealthStaminaHUD = false,
    FatigueSystem = false, MoodSystem = false, FearStressSystem = false,
    DistractionSystem = false, InjuryLimping = false, K9Medkit = false,
    ContrabandScreenFX = false,

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial = false, ProximityAudioFX = false, PropAttachments = false,
    FetchMechanic = false, DeployableKennel = false, CameraFeedPiP = false, -- experimental, see §7
}

Config.Peds = {
    { model = 'a_c_shepherd',   label = 'German Shepherd' },
    { model = 'a_c_rottweiler', label = 'Rottweiler' },
    { model = 'a_c_huskie',     label = 'Husky' },
    { model = 'a_c_chop',       label = 'Chop (K9 Unit)' },
    -- Adding a streamed custom model needs only a new entry here.
}

Config.Departments = {
    ['police']  = { label = 'Los Santos Police Department', certifierGrade = 4, autoAccessGrade = nil },
    ['sheriff'] = { label = 'Blaine County Sheriff',         certifierGrade = 3, autoAccessGrade = nil },
    ['bcso']    = { label = 'Blaine County Sheriff (legacy job name)', certifierGrade = 3, autoAccessGrade = nil },
}

Config.AllowSelfCertification = true   -- §4.1
Config.CertifyProximityMeters = 5.0    -- §4.2 item 4

Config.K9Vehicles = { 'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2' }
Config.VehicleInteractMeters = 3.0

Config.LeashMaxDistance = 8.0   -- meters before auto-recall-to-heel

Config.XPTiers = {
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRange = 5.0  },
    { xp = 500,  label = 'Trained K9', speedMultiplier = 1.05, scentRange = 6.5  },
    { xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRange = 8.0  },
    { xp = 3500, label = 'Elite K9',   speedMultiplier = 1.15, scentRange = 10.0 },
}

Config.ContrabandAlertTiers = {
    { minWeight = 1,   alert = 'whine' },
    { minWeight = 250, alert = 'aggressive_bark' },
}
```

---

## 6. Acceptance criteria by feature group

Each group is tagged with the phase it ships in. §6.1/§6.6/§6.7 are cited
directly from code and kept in full; §6.2–§6.5 and §6.8 are high-level
anchors only — their real detail lives in §11–§14, which superseded them.

### 6.1 Core Systems & Controls — Phase 1

The K9 player controls themselves at all times; nothing here spawns,
selects, or possesses a ped. "Handler" means a partnered human officer (§1).

- [ ] A player whose character is a K9, whose job is in `Config.Departments`,
      and who holds an active certification (§4) sees K9-specific UI; an
      uncertified K9-model player, or a certified player outside
      `Config.Departments`, does not — enforced server-side on every gated
      action, not just hidden client-side.
- [ ] Player can toggle first/third-person camera at the dog's eye height.
- [ ] Native quadruped run/jump/crouch, no custom animation work required.
- [ ] A "K9 Unit" radial submenu exposes: Bark, Sit, Attach/Detach Leash,
      Enter/Exit Vehicle. Each item's *registration* is gated on its owning
      `Config.Features` flag; the *access check* (`CanShowK9UI()`) is
      re-verified independently at `onSelect` time per item, not by
      live show/hide as access changes.
- [ ] Leash is a **consensual** two-player interaction with a **real
      movement restriction**:
      - **Attach requires consent** (accept/decline prompt on the target of
        the request) from either the K9 or a nearby officer. The non-K9
        side must satisfy `job.name ∈ Config.Departments` too (§9 item 9).
        Server determines which side is the K9 via the live model check
        (§4.5), never a client-asserted role.
      - **While attached, movement is actually restricted** — the leashed
        player is clamped/pulled back on approaching `Config.LeashMaxDistance`
        (soft elastic constraint), not merely notified.
      - **Either party can detach at will, no consent required** — a hard
        requirement: nothing may trap a player leashed with no self-service
        way out.
      - Exceeding the limit despite the pull-back (disconnect, teleport,
        desync) is a distinct safety-valve auto-detach, notifying both.
- [ ] Enter/exit any `Config.K9Vehicles` model via ox_target within
      `Config.VehicleInteractMeters`, self-administered; ped hidden/frozen
      while "in," restored on exit.
- [ ] Basic bark sound plays on radial trigger.
- [ ] Door interaction and full agility mode are **not** required in Phase 1
      — basic jump only.

### 6.2 Combat, Takedowns & Action — Phase 3
High-level anchor only; superseded in full detail by §12.

### 6.3 Scent & Advanced Tracking — Phase 2
High-level anchor only; superseded in full detail by §11.5.

### 6.4 Vision & Tactical Systems — Phase 2 (basic) / Phase 5 (PiP spike)
High-level anchor only; superseded in detail by §11.5 (vision) and §7/§15
`#phase-5-research` (PiP — concluded no PiP work is scheduled).

### 6.5 Qbox Integration, Inventory & Progression — Phase 4
High-level anchor only; superseded in full detail by §13.

### 6.6 Status, Vitality & Vulnerabilities — Phase 4
- [ ] NUI HUD shows health/stamina/hunger/thirst for the active K9, gated on
      `Config.Features.HealthStaminaHUD`.
- [ ] Fatigue: sustained sprint decays a value that reduces max speed when
      depleted; recovers faster near a configured rest source.
- [ ] Mood: drops on damage, restored by pet/feed interactions; sustained
      low mood applies a minor performance penalty.
- [ ] Fear/Stress: rises under sustained nearby gunfire, imposes a
      hesitation state above threshold until a "calm down" command or decay.
- [ ] Distraction: K9 immune to flashbang stun (integration-dependent, see
      §13.4.3.4); a thrown "meat bait" or "ultrasonic whistle" item triggers
      a configurable distraction state.
- [ ] Injury/limping: a "leg health" value below threshold blocks
      sprint/high-jump and reduces base speed via `SetPedMoveRateOverride`
      (no dedicated quadruped limp clipset assumed to exist).
- [ ] K9 medkit restores health/leg-health, gated the same way human medkit
      revives already are.
- [ ] Contraband screen effect uses `SetTimecycleModifier` with an existing
      GTA effect — no custom asset.

### 6.7 Audio & Immersion Props — Phase 5
- [ ] Radial bark options each play a distinct sound attached to the K9.
- [ ] Growl/pant volume attenuates by distance to a hiding suspect.
- [ ] Prop attachments (vest, harness, tracking camera) attach a configured
      prop to a configured bone via `AttachEntityToEntity`.
- [ ] Fetch: dog can pick up, carry, and drop a physics prop on command.
- [ ] Deployable kennel: K9 heals at an accelerated rate resting inside its
      radius.

### 6.8 Cross-cutting: config-driven & certification (Hard Requirements 1 & 2)
Covered by §3 and §4 — treat those as authoritative regardless of which
feature-group phase is being reviewed.

---

## 7. Scope reality check — native-only approximation vs. real asset need

| Requested item | Native-only approximation | What would need a custom asset |
|---|---|---|
| K9 camera feed PiP | A full-screen camera *takeover* toggle (`CreateCam`/`RenderScriptCams`) — not a true inset PiP. | A real inset PiP of live 3D world video needs a render-target/texture-capture path FiveM does not expose to plain Lua for a moving in-game camera. Concluded infeasible for a true feed; Phase 5 shipped only a feasibility spike, not a working PiP. |
| Thermal / night vision | `SetSeethrough(true)` for thermal (GTA's built-in heat-vision, highlights peds as heat sources), `SetNightvision(true)` for night — both confirmed, toggle-and-forget natives. | Nothing extra needed. |
| Bite-and-hold "locks onto arm/leg" | Task/animation + a control-disable flag on the target, released on Recall/timeout. | A literal physics-attached bite with correct IK needs custom animation work; not attempted. |
| Agility mode (climb fences/windows) | Native jump task + a scripted vault (capsule-sweep obstacle detection, §12.0 item 3) reposition over a detected low obstacle. | A real climbing animation blended to arbitrary fence heights needs a custom clip set. |
| Limping/injury gait | Reduced move-speed via `SetPedMoveRateOverride`, no distinct visual gait. | A visually distinct limping quadruped animation needs a custom clip set (none assumed to exist). |
| Permanent scar overlays | Not attempted. | Custom ped texture/decoration asset + pipeline; out of scope. |
| Contraband screen filter | `SetTimecycleModifier` reusing an existing GTA "drug effect" modifier. | Nothing extra needed. |
| Bark sounds | Achievable but needs **bundled audio asset files** — there is no native "make this canine ped emit a bark voice line on command." A small, easy-to-source asset need, not a scripting blocker. | Higher-fidelity/breed-specific variation needs a larger recorded library. |
| Prop attachments | `AttachEntityToEntity` onto an existing/repurposed prop if a close-enough one exists. | A purpose-built vest/harness/camera-housing model — base GTA doesn't ship one for a quadruped rig. |
| Deployable kennel | An existing GTA prop as a stand-in visual. | A purpose-built kennel model. |
| Gunpowder/blood tracking data sources | Achievable via native game events/polling, but needs authored client→server relay code (§11.6) — not literally free. | Nothing extra beyond that relay code. |
| Door interaction "nudge-open" | Scratch-to-alert (pure sound cue) is fully native-only. Nudge-open needs a real door-lock resource integration (§11.6) — GTA has no generic native lock-state query for arbitrary map doors. | No asset, but a genuine external-resource integration dependency. |

---

## 8. Phased build plan

All five phases have shipped; see `README.md`/`CHANGELOG.md` for current
state. Kept only as a one-line map from phase number to detail section:
Phase 1 = vertical slice (§3, §4, §6.1); Phase 2 = tracking & basic vision
(§11); Phase 3 = combat & advanced agility (§12); Phase 4 = inventory,
progression, vitality (§13); Phase 5 = audio/props polish + camera R&D
spike (§14, concluded no PiP work is scheduled — §7).

---

## 9. Open questions / assumptions needing sign-off

Numbering below is fixed — several items are cited by number directly in
code comments (`DEVELOPER_REFERENCE.md §9 item N`, formerly `SPEC.md §9 item
N`). Resolved items are kept, condensed, rather than removed or renumbered,
so those citations keep resolving to something meaningful.

1. ~~DB table vs. metadata for certification.~~ **Resolved** — dedicated
   table, §4.3.
2. **Cross-department certifying (§4.2 item 3).** A certifier from one
   allowed department may certify a target in a *different* allowed
   department. If same-department-only is wanted, that's a one-line change
   in the grant handler — a real behavioral fork, not silently picked
   either way.
3. ~~Does a cert survive a job change and later return?~~ **Resolved** — no,
   §4.4: a fresh grant is required even on rejoining the same department.
3b. ~~Two-player leash/command semantics.~~ **Resolved** — see §6.1's full
    corrected criteria: consent gates getting leashed, never getting free
    of it.
4. **Contraband alert weight thresholds and XP values
   (`Config.XPTiers`, `Config.ContrabandAlertTiers`, and — per §12.6/§13.5 —
   every numeric placeholder added by Phase 3/4) are unreviewed.** Needs an
   economy-balance/config-validator pass against real ox_inventory item
   weights and progression pacing before any owning flag defaults `true` on
   a live server.
5. **PvP-balance review for Phase 3** (cooldowns, interaction with any
   existing restraint/cuff system) — scope widened by §12.6 once PvP
   targeting was decided in scope (§12.0 item 1).
6. ~~Camera feed PiP feasibility.~~ **Resolved as infeasible for a true
   feed** (§7) — do not re-propose without new FiveM engine support.
7. **Bark/vest/harness/kennel audio and prop assets** — small
   asset-sourcing tasks (source, not necessarily commission royalty-free
   sound/prop assets), not zero-asset code-only work.
8. **Live model reliability across an appearance/model swap (§4.5).** If a
   server's separate appearance resource changes a player's base model
   mid-session, the live `GetEntityModel` check could theoretically read a
   stale-relative-to-intent value right around the swap. Not addressed
   speculatively — confirm the target server's actual appearance-system
   behavior before assuming a fix is needed.
9. ~~Must the non-K9 leash partner be in an allowed department too?~~
   **Resolved** — yes, department membership required (not its own K9
   cert) — §6.1.
10. ~~Real event/native availability for tracking data sources.~~
    **Resolved** — blood/gunpowder both need a small authored client→server
    relay (§11.6), not a free native feed; implemented in
    `server/tracking.lua`.
11. **ox_inventory export names/signatures** for search/contraband reading
    and (historically) scent-drop detection — confirmed for search
    (§15 `#contraband-search`) and for scent (item 17 below); K9
    Inventory/K9 Medkit's own export shapes (§13.4.2, §13.4.4) were flagged
    with the same caveat when written — verify against the live
    `overextended/ox_inventory` source before trusting an unconfirmed export
    shape in this document.
12. **Door interaction "nudge-open" needs a real door-lock resource to
    integrate with** — no such resource is in this project's scope, and GTA
    has no generic native for arbitrary map-door lock state. Scoped
    client-only, unlocked-doors-only (§11.6); a richer version needs a real
    per-server integration decision, not a guess.
13. ~~`Config.SearchContrabandItems` is a placeholder list.~~ Same review
    status as item 4 — needs an economy-balance/db-schema pass against the
    real ox_inventory items table.
14. **Whether tracking trail reveal needs a server-side rate-limit/anti-abuse
    surface beyond the per-type cooldown in `Config.Tracking`** — e.g.
    should a K9 be blocked from tracking while leashed-past-limit or during
    an active search-zone cooldown on the same target? Not resolved — a
    judgment call for whoever extends this, not a mandate either way.
15. ~~Did `relayDamageEvent` need an explicit rate limit, at parity with
    `relayWeaponFire`'s?~~ **Resolved** — yes, was a real gap; both trail
    types now have their own `relayCooldownMs` in `Config.Tracking`,
    stamped before any log-append work.
16. ~~Does `relayDoorScratch`'s `doorNetId` need an existence/proximity
    check before broadcasting?~~ **Resolved.** `server/main.lua`'s handler
    resolves the netId, confirms existence, checks live proximity with a
    documented latency margin, verifies entity type (objects only, closing
    a ped/vehicle netId substitution), and enforces both a per-source and a
    door-keyed cooldown — all before broadcasting.
17. **Scent tracking's server-side source resolution — was explicitly
    deferred, then implemented, one verification step still outstanding.**
    `exports.ox_inventory:registerHook('swapItems', ...)` (confirmed real,
    server-side, synchronous on item drop) is the mechanism; implemented in
    `server/tracking.lua`. **One disclosed gap remains:** the hook's exact
    payload shape was confirmed by source-reading, not by an independent
    test against a live `ox_inventory` install — see `OPERATOR_RUNBOOK.md`
    §2a for the five-minute live check that closes this gap.

---

## 10. Consultations not available this session

Peer-agent spawning was restricted to the top-level session when this
document was written, so **db-schema** was not able to review §11.3/§11.4's
ephemeral (non-persisted) tracking-event-log design (`server/tracking.lua`)
to confirm in-memory-only is the right call there, the same way it reviewed
§4.3's certification table. Still cited from inside `server/tracking.lua`
as a standing, not-yet-closed item — if that design is ever revisited,
confirm in-memory-only against `LeashPairs`' identical precedent rather
than assuming it's settled by precedent alone.

---

## 11. Phase 2 Detailed Spec

### 11.1 Sub-phase ordering (dependency graph)

| Sub-phase | Features | Why this order |
|---|---|---|
| 2a — independent, parallelizable | `ThermalVision`, `NightVision`, `DoorInteraction` (scratch-to-alert only) | Pure/near-pure client-side, no shared state. |
| 2b — foundational | `SearchZones` | Must land before `ContrabandAlerts` — alert tiers are computed from a search's weight result. |
| 2c — depends on 2b | `ContrabandAlerts` | Consumes `SearchZones`' weight computation directly. |
| 2d — independent of 2b/2c | `ScentTracking` | Different data source (item-drop location), no hard dependency. |
| 2e — shared infra, land together | `BloodTracking`, `GunpowderSniffing` | Both need the same new relay-and-log infrastructure (`server/tracking.lua`) — avoid two divergent copies. |
| 2f — depends on 2d/2e | `WaterTrackingDecay` | A modifier on an existing rendered trail, not standalone — needs a trail to already exist. |
| Door interaction, nudge-open half | (still `DoorInteraction`) | Split from 2a — depends on confirming a door-lock resource integration (§9 item 12); scratch-to-alert ships regardless. |

### 11.2 Config schema additions

```lua
-- Ranges in meters, ages/windows in seconds. Each trail TYPE is gated by its
-- own Config.Features flag; tables below only take effect for enabled types.
Config.Tracking = {
    Scent     = { maxRange = 40.0, markerSpacing = 3.0, searchCooldownMs = 5000 },
    Blood     = { maxRange = 40.0, maxAgeSeconds = 300, markerSpacing = 3.0, searchCooldownMs = 5000 },
    Gunpowder = { maxRange = 40.0, maxAgeSeconds = 120, markerSpacing = 3.0, searchCooldownMs = 5000 },
    -- Blood/Gunpowder each also carry their own relayCooldownMs (§9 item 15),
    -- and Scent's maxAgeSeconds/relayCooldownMs were added when item 17 shipped.
}

-- Water crossing degrades/breaks a visible trail — not a trackable type of
-- its own, applies to whichever trail (scent/blood/gunpowder) is active.
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0, -- use GetWaterHeightNoWaves, NOT GetWaterHeight -- plain GetWaterHeight's wave-motion jitter causes inconsistent reads between adjacent samples on calm shorelines
    breaksTrail          = true, -- true: hard break, re-search required on far bank. false: fade opacity near/in water instead
}

-- Item names must match real ox_inventory item names on the target server —
-- PLACEHOLDER list (§9 item 13). Item WEIGHT is read live from ox_inventory's
-- own item registry at search time, never duplicated here.
Config.SearchContrabandItems = { 'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol' }

Config.SearchZones = {
    vehicleSearchDistance = 2.0, personSearchDistance = 2.0,
    sniffAnimDurationMs   = 4000,
    searchCooldownMs      = 10000, -- per-(K9, target) -- prevents repeat-search spam/harassment
}

-- nudgeRequiresUnlocked is a hard requirement, not a toggle: nudge-open must
-- never function as a lockpick bypass (§11.6).
Config.DoorInteraction = {
    interactDistance = 1.5, nudgeRequiresUnlocked = true, scratchCooldownMs = 3000,
}

Config.Vision = {
    Thermal = { toggleKey = 'K' }, -- drives SetSeethrough (§11.6)
    Night   = { toggleKey = 'J' }, -- drives SetNightvision (§11.6)
}
```

### 11.3 File/module plan

Continuing Phase 1's boundary conventions (thin radial wiring only in
`client/radial.lua`; "own body" self-actions in `client/movement.lua`;
target-entity interactions in their own per-type file; small
server-authority-only actions in `server/main.lua`).

| File | New/extends | Owns |
|---|---|---|
| `client/tracking.lua` | New | Scent/blood/gunpowder self-search radial items, trail marker rendering, water-crossing degrade. Calls `qbx_k9unit:server:findTrackableSource` (§11.4). Separate from `movement.lua` to keep that file's own scope (camera/sit/leash) from growing into an everything-file. |
| `client/search.lua` | New | Search-vehicle/search-person ox_target options; plays the sniff animation, awaits `qbx_k9unit:server:searchTarget` (§11.4). Kept separate from `client/tracking.lua`: tracking reveals a cosmetic trail (no real capability granted), search reveals real server-verified inventory contents (a real capability) — split by trust model, not just by feature name. |
| `client/vision.lua` | New | Thermal/night vision keybinds (`RegisterKeyMapping`) — a cheap, local, free `IsOwnModelK9()` check, not gated behind `CanShowK9UI()` (a perception QoL toggle, not a granted capability, same category as the camera toggle). |
| `client/movement.lua` | Extends | Door interaction (nudge + scratch) — small enough to be a self-action alongside Sit rather than its own file. Nudge-open ships client-only, no server event (§11.6) — mirrors vehicle entry/exit's §4.1 exception. |
| `server/tracking.lua` | New | Event-relay log backing blood/gunpowder: logs a damage-event/weapon-fire coordinate read server-side from the reporter's own live position (never client-supplied), a periodic prune pass, and `qbx_k9unit:server:findTrackableSource`. Ephemeral/in-memory only, mirroring `LeashPairs`' precedent (§10). |
| `server/search.lua` | New | `qbx_k9unit:server:searchTarget` — re-validates flag/access/live proximity, reads real inventory via an ox_inventory server export, cross-references `Config.SearchContrabandItems`, computes weight from live item data, looks up the alert tier, applies cooldown, broadcasts the alert if `ContrabandAlerts` is on. |
| `server/main.lua` | Extends | Door scratch-to-alert only (`relayDoorScratch`) — structurally identical to the existing `relayBark` handler. Nudge-open gets no server entry. |
| `client/radial.lua` | Extends | Three self-action items (Track Scent/Blood/Gunpowder) under the K9 Unit submenu, each gated by its own flag. |
| `config.lua` / `fxmanifest.lua` | Extend | Add §11.2's tables; add the new client/server files to their script lists. |

### 11.4 Event/callback contract (Phase 2)

**Callbacks (ox_lib `lib.callback`):**
1. `qbx_k9unit:server:findTrackableSource(trackType: 'scent'|'blood'|'gunpowder')`
   → `{ found, coords?, breaksAtWater }` [`server/tracking.lua`]. Re-validates
   flag/access; resolves the caller's own live position, never a
   client-supplied coordinate; enforces `Config.Tracking.<Type>.searchCooldownMs`.
2. `qbx_k9unit:server:searchTarget(targetType: 'vehicle'|'person', targetNetId)`
   → `{ ok, reason?, contrabandFound?, totalWeight?, alertTier? }`
   [`server/search.lua`]. **The security-critical one.** Re-validates
   flag/access, resolves `targetNetId` server-side and confirms it exists
   within range of the caller's own live position, cross-checks the
   resolved entity's real type against the client-claimed `targetType`
   (rejects a mismatch with `invalid_target` before any inventory read).
   Reads real inventory contents and real item weights — never a
   client-supplied claim. `totalWeight`/`contrabandFound` return **only to
   the caller**, never broadcast (only `alertTier` is ever sent to anyone
   else). Enforces **two** independent cooldowns — per-`(source,
   targetNetId)` and a flat per-`source` floor — both timestamped **before**
   the awaited ox_inventory call starts, closing a TOCTOU window a
   post-completion timestamp would leave open. Must recurse into container
   items to a bounded depth (else "put the drugs in a bag" defeats the
   feature entirely); must use an in-flight mutex per source (closes a
   same-source concurrent-call race); must treat a failed/errored inventory
   query as a distinct `search_failed` outcome, never collapsed into
   "clean"; `Config.ContrabandAlertTiers` needs an explicit baseline
   `{ minWeight = 0, alert = 'clean' }` entry so a genuinely clean search
   has defined feedback. Full export-signature detail in §15 `#contraband-search`.

**Server events (client→server):**
3. `qbx_k9unit:server:relayDamageEvent()` [`server/tracking.lua`] — from a
   client's own `CEventNetworkEntityDamage` handler when the local player is
   the victim. No meaningful payload — the server logs the reporter's own
   live coordinates.
4. `qbx_k9unit:server:relayWeaponFire()` [`server/tracking.lua`] — from a
   debounced local `IsPedShooting` false→true transition. Same
   own-live-coordinate rule; needs its own tight per-player rate limit,
   independent of the *search*-side cooldown (this is a *logging* cooldown).
5. `qbx_k9unit:server:relayDoorScratch(doorNetId)` [`server/main.lua`] —
   structurally identical to `relayBark`; see §9 item 16 for the
   validation this handler performs before ever broadcasting.

**Client events (server→client):**
6. `qbx_k9unit:client:playDoorScratch(netId)` [`client/movement.lua`] —
   mirrors `playBark` exactly.
7. No dedicated event for tracking/search results — both are
   request/response shaped, so `lib.callback` is the right fit.

**Nudge-open has no event or callback at all** — fully client-local (§11.3,
§11.6), same exception class as vehicle entry/exit.

### 11.5 Acceptance criteria by feature

**Scent tracking** (`ScentTracking`)
- [ ] A qualifying player can trigger "Track Scent"; a non-qualifying
      caller hitting the callback directly gets `found = false` regardless
      of client UI state.
- [ ] Resolves the nearest configured source within `maxRange` of the K9's
      live server-side position.
- [ ] Renders trail markers spaced `markerSpacing` apart on success.
- [ ] Re-triggering before `searchCooldownMs` elapses is rejected
      server-side.
- [ ] With the flag `false`, the radial item is absent and the callback is
      an unconditional server-side no-op.

**Blood trail tracking** (`BloodTracking`)
- [ ] Identical to scent above, but sourced from the most recent logged
      damage-event location within `maxAgeSeconds`, victim's own live
      server-side position at report time, never client-claimed.

**Water tracking / scent degradation** (`WaterTrackingDecay`)
- [ ] Any active trail is sampled every `sampleIntervalMeters` for water.
- [ ] `breaksTrail = true` (default): rendering stops at the water's edge, a
      fresh search is required on the far bank. `false`: reduced-opacity
      markers instead, trail continues.
- [ ] With the flag `false`, trails render through water with no
      degradation.

**Gunpowder residue sniffing** (`GunpowderSniffing`)
- [ ] Identical to scent, sourced from the most recent logged weapon-fire
      location within `Config.Tracking.Gunpowder.maxAgeSeconds`, logged from
      the shooting player's own live position.

**Search vehicle/person + contraband alert tiers** (`SearchZones`, `ContrabandAlerts`)
- [ ] ox_target "Search Vehicle"/"Search Person" appear within configured
      range while passing `CanShowK9UI()`; the sniff animation is purely
      cosmetic pacing — the server computes the real result.
- [ ] The server determines contraband found/weight from the target's real
      live inventory — a spoofed client claim changes nothing.
- [ ] Crossing a `Config.ContrabandAlertTiers` tier plays that tier's alert
      as a broadcast sound/animation audible to nearby players, not just
      the requester.
- [ ] With `ContrabandAlerts = false`, a successful search still reports
      `contrabandFound`/`totalWeight` to the requester, but no broadcast
      alert fires — this flag gates the *alert*, not the *search*.
- [ ] Re-searching the same target before `searchCooldownMs` (per
      `(K9, target)` pair) is rejected, not silently re-rolled.
- [ ] With `SearchZones = false`, neither option appears and the callback
      rejects `ok = false` for any caller.

**Door interaction** (`DoorInteraction`)
- [ ] "Nudge Open" appears only on an already-unlocked door
      (`nudgeRequiresUnlocked = true`) — a hard behavioral guarantee, not
      just a default; fully client-local.
- [ ] "Scratch to Alert" works regardless of lock state, triggers
      `relayDoorScratch`, rejected server-side within `scratchCooldownMs`.
- [ ] With the flag `false`, neither option appears and `relayDoorScratch`
      is a server-side no-op.

**Thermal vision** (`ThermalVision`) / **Night vision** (`NightVision`)
- [ ] Gates on `IsOwnModelK9()` only, **not** `CanShowK9UI()` — the K9's own
      innate perception, same reasoning as the camera toggle, applied
      identically to both.
- [ ] Toggling calls `SetSeethrough`/`SetNightvision` respectively — no
      custom shader/asset.
- [ ] Auto-disables on resource stop (mirrors `client/vehicle.lua`'s
      restart-safety precedent) and on every other exit path (death,
      disconnect, cert auto-revoke mid-session) — nothing else turns these
      global toggles off.
- [ ] Thermal and night vision are mutually exclusive at any given moment
      (a judgment call, not dictated by the original wording).

### 11.6 Reality-check refinements

- **Thermal/night vision — confirmed achievable.** `SetSeethrough(true)`
  (GTA's built-in heat-vision, used by the base game's Predator event and
  Cayo Perico thermal goggles) is the better fit over a generic timecycle
  modifier — it actually highlights peds as heat sources. `SetNightvision(true)`
  is the standard NV effect. Both toggle-and-forget, zero new assets.
- **Gunpowder sniffing — no single free native feed exists.** Each client
  polls its own `IsPedShooting` and relays a debounced event on a
  false→true transition (§11.4 item 4) — small, authored, still 100%
  native-based.
- **Blood trail — same relay caveat.** `CEventNetworkEntityDamage` is real
  and documented, but fires locally per-client — the victim's own client
  relays it (§11.4 item 3).
- **Scent tracking (item-drop location) — resolved.**
  `exports.ox_inventory:registerHook('swapItems', ...)` fires server-side,
  synchronously, on every item drop, carrying `payload.source` — resolvable
  to a live position the same way damage/weapon-fire relays already are.
  Implemented in `server/tracking.lua`; see §9 item 17 for the one
  remaining verification gap.
- **Search vehicle/person contraband reading** — unambiguously possible;
  exact export names confirmed in §15 `#contraband-search`.
- **Door interaction "nudge-open" — a genuine integration dependency.** GTA
  has no generic native to query/set lock state on arbitrary map/interior
  doors; that state lives entirely inside a separate, server-specific
  door-lock resource with no vanilla native surface to query from outside
  it. This is why nudge-open is scoped strictly to "only when already
  unlocked," client-only, with no lock/unlock logic of its own — safe to
  ship without an integration decision, at the cost of being a thin,
  cosmetic-only feature. **GTA's native `CDoor` system must never be
  consulted as a safety check here even as a belt-and-suspenders measure**
  — most real door-lock resources manage state entirely outside `CDoor`, so
  an unregistered door reads as "nothing to say," which risks a
  false-negative "unlocked" read — a concrete way to violate the hard
  `nudgeRequiresUnlocked` guarantee. Implementation must stay purely
  cosmetic (a push animation on a door the K9 can already physically pass).
- **"Scratch to alert" — confirmed, no caveats.** Identical shape to
  `relayBark`.

### 11.7 Cross-reference

New open questions raised during Phase 2 scoping were appended to §9
(items 10–17) rather than duplicated here, so §9 remains the single running
list.

---

## 12.0 — Cross-cutting design forks: resolved and open

Item numbers below are fixed and cited directly by number throughout
`client/combat.lua`, `server/combat.lua`, `client/defense.lua`,
`server/defense.lua`, `server/partnership.lua`, `client/partnership.lua`,
`client/radial.lua`, `client/agility.lua`, `client/movement.lua`,
`server/fetch.lua`, `server/recall.lua`, and `config.lua`.

#### 1. PvP vs. PvE target scope — DECIDED: player-vs-player K9 combat is IN SCOPE

All four target-taking mechanics (`BiteAndHold`, `NonLethalTakedown`,
`PropDragging`, `HandlerDownDefense`'s target selection) can target **either
an NPC or a live player**, subject to item 5's eligibility gate for player
targets. This is a direct, explicit, informed product decision — not open
to re-litigation on "no ecosystem precedent for this" or "a modified client
can ignore the instruction" grounds; those tradeoffs were weighed and
accepted knowingly. What item 8 below settles is the concrete, honest
mechanics of that decision, not whether to make it. Player-vs-player K9
combat is **not** a §2 non-goal.

#### 2. HandlerDownDefense's "aggressive state" — DECIDED: UI/auto-targeting convenience, not AI takeover

The K9's bite-and-hold/takedown actions become available through a single
simplified, pre-targeted input instead of the radial menu — the K9 player
still steers their own ped and still confirms manually. A fully autonomous,
zero-input AI attack is rejected outright: it would require this resource
to take control of the K9 player's own ped, directly conflicting with §2's
non-goal and §1's "the K9 player controls themselves... at all times."
"Nearest hostile" can resolve to a live player, not only an NPC.

- [ ] A trigger never, by itself, moves the K9's ped, fires a weapon, plays
      a combat animation, or applies any task/control to the K9 player.
- [ ] The K9 player must manually confirm before any action executes.
- [ ] The K9 player retains full manual control of movement/camera at all
      times.
- [ ] Once confirmed, the action goes through the exact same
      `requestBiteHold`/`requestTakedown` server validation path as a
      manually-triggered action, including item 5's eligibility gate.
- [ ] A literal AI-takeover version remains a separately-scoped feature, not
      a configuration of `HandlerDownDefense`.

#### 3. AgilityAdvanced obstacle detection — DECIDED: capsule-sweep raycast (`detectionMethod = 'raycast'`)

`Config.Combat.AgilityAdvanced.detectionMethod = 'raycast'` is the Phase 3
default: a multi-height capsule sweep (`StartShapeTestCapsule`/
`GetShapeTestResult`, confirmed real natives). `'taggedProp'` remains
available as an optional per-server override. Independent of the PvP scope
question — this feature never targets anything.

#### 4. Non-consensual state application posture — RESOLVED

**Resolution: combat is a different category from leash and does not need
leash's consent model — a category difference, not a conflict.** Leash's
consent requirement exists because it's a **cooperative** mechanic;
bite-and-hold/takedown/dragging are **apprehension/enforcement actions** by
design — exactly like every comparable QBCore/Qbox mechanic (cuffing,
tasing, hogtying), none of which gate on the target's consent. Requiring
consent from a combat target would make the feature meaningless.

Because combat gives up consent, the compensating control is item 5 below —
read the two together. The leash's *other* guarantee ("no consent needed to
get free") has a real analog here even without the initiating-consent
carryover: the hard duration caps (`Config.Combat.BiteAndHold.maxDurationMs`,
`NonLethalTakedown`'s ragdoll/damage-suppression window,
`Config.Combat.PropDragging.maxDragDistance`) are this mechanic's version of
"no unbounded trap" — load-bearing for this non-consensual design being
acceptable at all, not just a balance knob.

#### 5. Target-eligibility restriction — RESOLVED: config-driven wanted/suspect gate

**Resolution: yes, restricted — `Config.Combat.RequireWantedStatus` (default
`true`).** A K9 may only initiate `BiteAndHold`/`NonLethalTakedown`/
`PropDragging` against a **player** target currently flagged wanted/suspect
by whatever dispatch system the server runs; an NPC target is unaffected
either way. **There is no native networked "wanted level" concept**, and
unlike item 6's laststand check, there is no single ecosystem-dominant
convention for exposing one — flagged as **lower confidence** than item 6's
default.

Integration point (same shape as item 6): (1) a best-effort default check
against a plausible metadata convention (`metadata.wanted`/`.iswanted`),
(2) `Config.Combat.WantedStatusCheckOverride(playerId) -> boolean` — expected
to be the *normal*, not exceptional, path for a real server, (3)
`RequireWantedStatus = false` remains available for a server that wants
unrestricted PvP K9 combat, but the shipped default is `true`.
Enforcement is server-side only, inside `requestBiteHold`/`requestTakedown`/
`requestDrag`'s validation. **Residual, disclosed gap:** this does not stop
an officer who manipulates their own server's dispatch/wanted system to
flag a colleague deliberately — that's an abuse vector of whatever *other*
resource controls wanted state, not something this resource re-verifies.

#### 6. PropDragging's "is this player downed" integration point — RESTORED, real requirement for the player-target path

NPC-target dragging is fully native (`IsPedDeadOrDying(ped, true)` +
`IsPedRagdoll`) and unaffected by this item. For a **player** target, those
same natives don't answer the actual question needed (this server's own
scripted downed/laststand state) — most QBCore/Qbox laststand
implementations keep the ped's health above zero with no native death state
(a false negative), while an unrelated ragdoll (knocked over by a vehicle)
would satisfy `IsPedRagdoll` without being "downed" in any real sense (a
false positive). This is a category mismatch between what the natives
observe and what the feature needs, not a confidence gap more research
would close.

**Required contract:** (1) a default check against `metadata.isdead`/
`.inlaststand` if present, (2)
`Config.Combat.PropDragging.IsPlayerDownedOverride(playerId) -> boolean` as
a real, wired-in (not commented-out) escape hatch. NPC-target dragging
remains fully unblocked regardless of this item's status; only the
player-target path is gated on step 1 existing in real, tested code.

#### 7. Handler-partnership link — RESOLVED: new persistent registry (Option B), NOT a reuse of `LeashPairs` (Option A, rejected outright)

**Why Option A is rejected, not merely deprioritized:** `LeashPairs` is
explicitly ephemeral, in-memory, session-scoped state for a
movement-restriction mechanic — reusing it as "who is my ongoing combat
partner" would silently repurpose transient state as a durable
relationship it was never designed to be, and it is torn down on distance
safety-valve, either party's own detach, cert revoke, and job change.
Concretely, `HandlerDownDefense`'s own motivating scenario is a foot chase
— a K9 pursuing a fleeing suspect while its handler, now alone and
unleashed (leash is actively counterproductive during a chase), takes
damage. Option A would leave `HandlerDownDefense` **non-functional for the
exact scenario it exists to cover**, working only in the rare case the pair
happens to still be leashed. That is a materially worse gap than this
document's other accepted, disclosed ones (item 5's wanted-status
fragmentation still lets the gate do its job in the common case) — it fails
the primary use case, not an edge case.

**The design, as shipped in `server/partnership.lua`:**
1. **Establishment** mirrors leash's own consent handshake — a "Partner Up"
   action, initiated by either party, requiring the other's explicit
   accept/decline (reusing the `PendingLeashRequests`-style TTL'd
   single-slot pattern). Eligibility re-verified server-side: both parties
   pass `HasK9Access`-equivalent checks for the same department, live
   proximity, and the K9-role party is on a configured model.
2. **Persistence is DB-backed** (`k9_partnerships` table), not ephemeral
   like `LeashPairs` — the entire point is to survive a resource restart
   mid-shift, which no in-memory table could recover from. Modeled on
   `k9_certifications`' conventions (append-mostly audit rows, an `active`
   flag, generated-column unique constraints — here needing **two**, since
   both "one active partnership per K9" and "one active partnership per
   handler" must hold), an in-memory cache refreshed on `PlayerLoaded` plus
   an `onResourceStart` backfill loop mirroring `certifications.lua`'s.
   A lighter "ephemeral but not leash-tied" middle option was considered
   and rejected — it would leave the identical restart-survivability gap,
   just relabeled.
3. **Termination:** either party can break it at will, no consent needed,
   plus automatic teardown on the same triggers that already force-detach a
   leash (added alongside every existing `ForceDetachLeashForSource`/
   `ForceDetachOfficerLeashForSource` call site in `server/certifications.lua`).
4. **Authorization:** mutual consent only, no certifier-grade hierarchy —
   partnership is a peer relationship between two already-independently-
   eligible parties, unlike certification granting.
5. New flag `Config.Features.HandlerPartnership`, new file
   `server/partnership.lua` — its own flag rather than piggybacking on
   `BiteAndHold`'s or `HandlerDownDefense`'s, so a server can disable
   partner-designation independently.

**Consumers:** `BiteAndHold`'s Recall actor checks
`Partnerships[recallerCitizenid].active and .partner == heldK9Citizenid`
server-side, in addition to (never instead of) an active hold-state entry.
`HandlerDownDefense`'s trigger looks up the handler's active partnership on
a health-threshold crossing; if none exists (never partnered, or broken),
it is a **silent no-op** — a real, disclosed prerequisite: a "Partner Up"
must have happened at least once for a given pair before `HandlerDownDefense`
can ever fire for them. State this explicitly in any player-facing doc.

#### 8. The client-relay architecture problem for a live-player target — RESOLVED

**Two categories of effect this resource applies to another entity:**
- **Category A** — effects an "owning" client can impose on another entity
  from outside it (`AttachEntityToEntity`, already used safely by
  `client/vehicle.lua`) — replicate across the network without the target's
  own client running any code.
- **Category B** — effects only real when the *target's own client*
  executes a local-only native on itself (`DisableControlAction`,
  `SetPedToRagdollWithFall`, `SetPedMoveRateOverride`,
  `SetEntityCanBeDamaged` bracketing). Nothing in FiveM lets the server or
  another client force a *different* client's ped into these states the
  way it can for an NPC.

Bite-and-hold and non-lethal takedown's restrictive effects are **entirely
Category B**. Prop dragging is **mixed**: the initial attach is Category A
(genuinely moves a target's rendered position regardless of cooperation —
the same technique underlying ecosystem cuffing/carry scripts), but the
speed limitation is Category B. **New finding: the attach must be
re-asserted every tick from the K9's own client, never one-shot** —
`AttachEntityToEntity` requires no ownership/authority over the target to
take effect (citizenfx/fivem issue #3726), and by the same evidence
`DetachEntity` isn't gated any differently — a hostile target's own client
can call `DetachEntity` on itself at any moment. A one-shot attach would
silently degrade dragging's Category A half into something as trivially
defeated as a Category B effect.

**Detection (real, buildable) vs. enforcement (not viable) against a
non-cooperating target:**
- **Purely cosmetic, no server-enforced restriction, is rejected as the
  answer** — this resource does not describe a Category B effect as
  "restraining" a player without a best-effort caveat.
- **Detection is real and implementable.** The server already has
  authoritative position for every networked entity, including a player's
  own ped. Add a `compliance` sub-record to the same per-effect state
  `server/combat.lua` already owns (never a second, independently-lifecycled
  table). One shared sampling thread (not one per effect) evaluates every
  active hold/ragdoll/drag entry every
  `Config.Combat.NonComplianceDetection.positionSampleWindowMs`. Per-effect
  threshold logic differs deliberately: `BiteAndHold` flags sustained
  speed over an idle-jitter ceiling across **two or more consecutive
  samples**, not one (`speedTolerance = 1.0` in the shipped placeholder is
  too loose for this specific check — recommend ~0.5 m/s when
  config-validator reviews §12.2); `NonLethalTakedown` uses **net
  displacement across the whole window**, not continuous speed, since a
  genuine ragdoll produces noisy non-directional velocity; `PropDragging`
  compares the target's position against the **K9's own live position**
  (a bounded slack), catching self-detach, a bypassed override, or the K9's
  own client failing to re-assert the attach, all as one signal. On
  violation: `'log'`/`'notify_staff'` only, **never** `'auto_kick'`/
  `'auto_ban'` by default — a server-side heuristic sampled every
  250–500ms over OneSync will produce false positives from ordinary
  lag/desync, and this resource has no standing to auto-punish on that
  basis; `OnViolationOverride(playerId, effectType, evidence)` lets a
  server build its own automated response on top of real evidence.
- **Enforcement (forced network-ownership migration) — evaluated and
  rejected, not "needs a prototype."** The cooperative request path
  (`NetworkRequestControlOfEntity`) is a best-effort ask of the current
  owner, not server-forceable — and a hostile client can opt out of
  incoming requests entirely via a documented native, with zero server-side
  visibility into whether it did (citizenfx/fivem issue #3338). The one
  server-forceable candidate, `NetworkSetEntityOwner`, remains an unmerged
  PR (#2312) that FiveM's own maintainers call "a somewhat undesirable
  command" carrying "risk of side effects," already misbehaving for the
  *easier* case (population entities) before the discussion even reaches a
  live player's own ped. Structurally, a live player's ped's ownership
  isn't a flag that migrates — it's what "being that player's client"
  means; even a successful request leaves a hostile client free to
  re-request immediately. And deliberately fighting another client for
  entity control every frame is, to any anti-cheat heuristic, indistinguishable
  in shape from a teleport/desync exploit — a new anti-cheat exposure this
  project's own false-positive standard would otherwise reject creating.

**Ship decision: ship it, with binding guardrails, not as an unconditional
restraint.** The requester already accepted this specific tradeoff, with
eyes open, when overriding NPC-only scope (item 1) — this is not the same
shape of gap as a genuinely-fixable client-trust hole (like an unvalidated
netId); it's a residual property of what a live player's own ped is in
FiveM's networking model, which no implementation discipline closes.
**Binding guardrails, required before any player-target code path ships:**
1. The detection layer above exists in real, tested code in
   `server/combat.lua`, not merely the config placeholder table.
2. `PropDragging`'s attach is re-asserted every tick, never one-shot.
3. **No server-authoritative consequence of any kind (arrest completion,
   evidence, currency, items, permissions) may ever be conditioned on a
   Category B effect having been applied successfully to a player target**
   — only on things this server independently verifies. This is the
   concrete backstop keeping "detection-plus-log" an acceptable posture
   rather than a fig leaf; do not add this coupling later without
   re-opening this item.
4. Every player-facing string describing these three mechanics' effect on a
   player is worded as best-effort ("attempts to restrain"), never as an
   unconditional guarantee.
5. `RequireWantedStatus` stays `true` by default and
   `NonComplianceDetection.action` stays `'log'`/`'notify_staff'` by
   default in this resource's own shipped config.

**Trust-boundary note:** the `qbx_k9unit:client:apply*` handlers this item
introduces are the first surface in this resource that must run
unconditionally on **any** connected player's client, including one who has
never touched a K9 feature — the server-side validation in
`server/combat.lua` is the *only* thing standing between "any connected
player" and this code firing against them. Review it with the same rigor as
the certification grant path, not less. See also §15 `#trust-boundary` for
the client-event origin-guard this depends on.

---

## 12.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| 3a — independent | `AgilityAdvanced` | Pure own-body movement, unaffected by PvP scope. |
| 3b — foundational, depends on `server/partnership.lua` (item 7) | `BiteAndHold` | Establishes the shared hold/incapacitate state + Recall actor every later feature reuses; first feature needing the Category A/B relay split and eligibility gate (items 5/8). |
| 3c — depends on 3b's target infra | `NonLethalTakedown` | Reuses the target-effect shape; additionally needs the server-computed speed gate. |
| 3d — depends on 3b/3c | `PropDragging` | NPC-target path fully unblocked; player-target path blocked on item 6's contract and shares item 8's speed-limit-relay exposure. |
| 3e — depends on Phase 2's tracking infra AND `server/partnership.lua` (item 7) | `HandlerDownDefense` | Pure consumer of 3b/3c's own target-action paths. |

## 12.2 Config schema additions

**Every numeric value below is an unreviewed placeholder** — flagged for a
PvP-balance/config-validator pass (§9 item 5) before any of this is relied
on as tuned. Detection-layer knobs specifically implement item 8's design,
not a separately-invented one.

```lua
Config.Combat = {
    -- Applies to all three player-targeting mechanics. Item 5.
    RequireWantedStatus       = true,
    WantedStatusCheckOverride = nil,  -- function(playerId) -> boolean

    -- Item 8 — DETECTION ONLY, NOT ENFORCEMENT.
    NonComplianceDetection = {
        enabled = true, positionSampleWindowMs = 500,
        speedTolerance = 1.0,  -- UNTUNED -- see item 8: too loose for BiteAndHold specifically, ~0.5 recommended there
        action = 'log',        -- 'log' | 'notify_staff' -- never 'auto_kick'/'auto_ban'
    },

    BiteAndHold = { range = 2.5, maxDurationMs = 15000, cooldownMs = 20000 }, -- maxDurationMs is item 4's "no unbounded trap" guarantee
    NonLethalTakedown = {
        range = 3.0, minTargetSpeed = 4.0, -- server-computed, never client-claimed
        cooldownMs = 25000, targetCooldownMs = 30000, healthFloor = 100, -- backstop only; primary mechanism is the SetEntityCanBeDamaged bracket
    },
    HandlerDownDefense = {
        handlerHealthThreshold = 100, triggerRadius = 15.0, hostileLookbackSeconds = 10, -- "hostile" may resolve to a player, subject to the same RequireWantedStatus gate as a manual trigger
    },
    PropDragging = {
        range = 2.0,
        dragSpeedMultiplier = 0.6, -- via SET_PED_MOVE_RATE_OVERRIDE, must be re-asserted every tick (item 8)
        maxDragDistance = 30.0,    -- unrelated to Config.LeashMaxDistance
        IsPlayerDownedOverride = nil, -- REQUIRED wiring before the player-target path ships, item 6
    },
    AgilityAdvanced = {
        detectionMethod = 'raycast', -- item 3
        maxVaultHeight = 1.2, vaultCooldownMs = 2000,
    },
}
```

## 12.3 File/module plan

| File | New/extends | Owns |
|---|---|---|
| `client/combat.lua` | New | BiteAndHold/NonLethalTakedown self-initiated triggers, PropDragging's client trigger. Registers, **unconditionally for every client** (see item 8's trust-boundary note), the target-side handlers `applyBiteHold`/`forceRagdoll`/`applyDragSpeedLimit`. |
| `server/combat.lua` | New | Server authority for BiteAndHold/NonLethalTakedown: access/range/target-scope validation, `IsPedAPlayer` resolution (never client-claimed), item 5's gate, the server-side speed gate, health-floor + damage-bracket application (direct for NPCs, relayed for players per item 8), the ephemeral hold/drag state, and item 8's `NonComplianceDetection` sampling. |
| `client/defense.lua` | New | HandlerDownDefense's client-side presentation **only** — per item 2, never applies state to or takes control of the K9's own ped; streamlines target selection into `client/combat.lua`'s existing action paths. |
| `server/defense.lua` | New | Hooks Phase 2's damage-event log; on a partnered handler's health crossing threshold, looks up `server/partnership.lua`'s registry (item 7) and notifies the partner K9 if online, silent no-op otherwise. |
| `server/partnership.lua` | New (item 7) | The `k9_partnerships` registry: DB table, in-memory cache, "Partner Up" handshake, teardown wired alongside every `ForceDetachLeashForSource`/`ForceDetachOfficerLeashForSource` call site, `PlayerLoaded`/`onResourceStart` backfill. Own flag, `Config.Features.HandlerPartnership`. |
| `client/movement.lua` | Extends | `AgilityAdvanced`'s vault trigger and capsule-sweep detection (item 3). |
| `config.lua` / `fxmanifest.lua` | Extend | Add §12.2's table; add the new files to their script lists. |

## 12.4 — Per-feature detailed spec

### 12.5.1 Bite-and-Hold (`Config.Features.BiteAndHold`)

Trigger: radial "Bite & Hold" within `range` of an eligible target — NPC or
player (item 1), passing `CanShowK9UI()`. Effect: latch/bite animation; the
target enters a "held" state up to `maxDurationMs` (item 4's "no unbounded
trap" cap), ending early on the K9's own "Release" or the registered
partner's "Recall" (item 7). Against an NPC, suppression applies directly
(`SetBlockingOfNonTemporaryEvents`/`SetPedFleeAttributes`). Against a
player, the restrictive half is relayed via `applyBiteHold` to the target's
own client (item 8 — no guarantee against a non-cooperating client), and
item 5's `RequireWantedStatus` gate must pass. One hold at a time per K9; a
target already held is rejected `already_held`.

Reality check: task/animation plus control-disable/AI-suppression, not a
literal rigid-body bite (§7). Anim candidate:
`creatures@rottweiler@melee@streamed_core@`/`takedown_from_back` — MEDIUM
confidence, needs an in-engine preview.

Event contract: `qbx_k9unit:server:requestBiteHold(targetNetId)`
[client→server] re-validates flag/access/proximity/not-already-held,
resolves player-vs-NPC via `IsPedAPlayer`, applies item 5's gate for a
player target; on success opens the hold-state entry and either suppresses
directly (NPC) or sends `qbx_k9unit:client:applyBiteHold(holderNetId, expiresAt)`
to the target only (player). `qbx_k9unit:server:releaseBiteHold()`
[client→server]. Server-side timeout past `maxDurationMs` auto-clears.
Never client-authoritative: active/expiry/suppressed/eligible state are all
server-held.

Open: item 8's residual gap for the player-target path; exact anim quality;
no damage over the hold duration (recommended, not enforced elsewhere).

### 12.5.2 Non-lethal takedown (`Config.Features.NonLethalTakedown`)

Trigger: same radial pattern, requiring the target's **server-computed**
speed over recent position samples to exceed `minTargetSpeed` — never a
client-reported "I am fleeing" claim; works identically for NPC or player
targets since the server has authoritative position for both. Effect:
`SET_PED_TO_RAGDOLL_WITH_FALL` + a damage bracket
(`SetEntityCanBeDamaged(false)`/`(true)`) — the primary non-lethal
mechanism, not the `healthFloor` backstop. Against a player, both are
Category B, relayed via `forceRagdoll` (item 8's caveat applies); item 5's
gate must pass. `SET_ENTITY_INVINCIBLE` is deliberately not used — it would
fight the ragdoll's own visual convincingness.

Event contract: `qbx_k9unit:server:requestTakedown(targetNetId)`
[client→server] — same validation shape as bite-and-hold plus the speed
gate (`not_fleeing` on failure). `qbx_k9unit:client:forceRagdoll(expiresAt)`
[server→client, target only]. Per-K9 and per-target cooldowns apply to
both target types.

Open: item 8's residual gap; the rolling speed-history state per targetable
entity; whether a takedown should leave a state some other cuff/restraint
resource can consume — not decided here.

### 12.5.3 Handler-down defense (`Config.Features.HandlerDownDefense`)

Trigger: a certified handler's health drops below `handlerHealthThreshold`,
detected via Phase 2's damage-event log. "Nearest hostile" = whoever the
log attributes as the source of the handler's most recent damage within
`hostileLookbackSeconds` — may now resolve to a player (item 1), which does
**not** exempt it from item 5's `RequireWantedStatus` gate at the
downstream validation step; an ineligible auto-selected target simply fails
the same way a manual attempt would, and the K9 player falls back to the
normal radial flow. **Partnership-gated (item 7):** `server/defense.lua`
looks up the handler's active partnership; if none exists (never partnered,
or broken), this is a **silent no-op** — state this prerequisite explicitly
in any player-facing doc, since mere certification is no longer sufficient
on its own.

Reality check: needs no new native capability; inherits whatever compliance
posture BiteAndHold/NonLethalTakedown land on for their player-target
paths.

### 12.5.4 Prop dragging (`Config.Features.PropDragging`)

Trigger: radial "Drag" on a nearby target within `range` that is currently
"downed." NPC: native `IsPedDeadOrDying(ped, true)` + `IsPedRagdoll` — fully
unaffected by anything below. Player: item 6's two-part contract
(`metadata.isdead`/`.inlaststand` default + `IsPlayerDownedOverride`), not
the native checks. Effect: `AttachEntityToEntity` near a collar/scruff point
(Category A, per item 8 — re-asserted every tick, not one-shot) at
`dragSpeedMultiplier` of normal speed via `SET_PED_MOVE_RATE_OVERRIDE`
(also re-asserted every tick); for a player target, the speed limitation
specifically is relayed via `applyDragSpeedLimit` (Category B, item 8's
caveat applies to this half only — the attach itself is comparatively
robust). Movement continues up to `maxDragDistance` before auto-release
(distinct from `Config.LeashMaxDistance`). Either the K9 or the dragged
player can end the drag at will, no consent needed either direction —
mirrors leash's "no consent needed to get free" rule, applied to a target
who never consented to entering either (item 4).

Event contract: `qbx_k9unit:server:requestDrag(targetNetId)` [client→server]
— validates flag/access/proximity, the appropriate downed check per target
type, and item 5's gate for a player target.
`qbx_k9unit:client:applyDragSpeedLimit(expiresAt)` [server→client, player
target only]. `qbx_k9unit:server:releaseDrag()` [client→server, either
party]. Distance/expiry safety valve via `maxDragDistance`.

### 12.5.5 Advanced agility — fence/window vault approximation (`Config.Features.AgilityAdvanced`)

Extends `client/movement.lua`'s existing `AgilityBasicJump` precedent
(same "own body" file). A manual radial/keypress trigger fires a scripted
vault (`SetEntityVelocity` reposition, optionally layered with
`TaskPlayAnim`) when moving toward a detected low obstacle under
`maxVaultHeight`, subject to `vaultCooldownMs`. Obstacle detection: item 3's
decided multi-height capsule sweep. There is no generic ped "jump task"
native — jump is native-locomotion/input-driven, not a scriptable task; the
arc is layered on top of or driven independently of that input.

Reality check: native-only mechanical approximation, no real climbing
animation exists or is expected to. Open: in-engine tuning of the sweep's
height bands/capsule radius/forward distance; exact vault
natives/animation pairing for a quadruped skeleton — genuinely unresolved,
no candidate clip found.

---

## 12.6 — Cross-cutting notes carried forward from §9

- §9 item 5 (PvP-balance review) applies to every value in §12.2, widened to
  re-cover items 4/5 now that PvP is in scope, and should weigh in on item
  8's `NonComplianceDetection` knobs once built.
- Recommend a security pass confirming item 5's gate is enforced in all
  three player-targeting validation paths (never trusting a client's claim
  that a target is a player or eligible), item 2's acceptance criteria are
  met exactly, and item 8's guardrails 2/3 are actually implemented (not
  merely documented) once `server/combat.lua` exists.
- Item 7 is resolved — what remains is `server/partnership.lua` existing as
  real, tested code, not further design.
- The `qbx_k9unit:client:apply*` handlers (item 8) are the first
  client-side surface that must run generically on any connected player —
  deserve the same file-boundary/trust-model scrutiny as everywhere else in
  this codebase.

## 12.7 — Quick-reference: decisions

1. PvP vs. PvE scope — **decided in scope** (item 1).
2. HandlerDownDefense's aggressive state — **decided**, UI convenience only
   (item 2).
3. AgilityAdvanced detection — **decided**, capsule-sweep raycast (item 3).
4. Non-consensual application posture — **resolved**, a different category
   from leash, compensated by item 5 (item 4).
5. Target-eligibility — **resolved**, `RequireWantedStatus` config-driven
   gate, default `true` (item 5).
6. PropDragging's downed-check for a player target — **resolved**, a
   required two-part contract; NPC-target path unaffected (item 6).
7. Handler-partnership link — **resolved**, new DB-backed registry, Option A
   (`LeashPairs` reuse) rejected outright (item 7).
8. Client-relay/non-cooperating-target architecture — **resolved**: forced
   network-ownership migration rejected as unviable; ship with detection +
   binding guardrails instead (item 8).
9. Native/animation verification still outstanding: bite/attack anim visual
   quality across breeds, vault animation for a quadruped skeleton —
   unresolved, not design questions.
10. Every numeric placeholder in §12.2, including `NonComplianceDetection`'s,
    needs a PvP-balance/config-validator pass before any flag defaults
    `true` — item 8 specifically flags `speedTolerance = 1.0` as too loose
    for `BiteAndHold`, recommending ~0.5 as a starting point.

---

## 13.0 — Cross-cutting architectural decisions

### Decision 1: `FatigueSystem`/`MoodSystem`/`FearStressSystem`/`DistractionSystem`/`InjuryLimping` are ONE subsystem, not five

All five ship as one `client/wellbeing.lua` + `server/wellbeing.lua` pair,
one `Config.Wellbeing` table, one per-citizenid stat store — each
`Config.Features.*` flag independently gates only that stat's own tick
logic and gameplay effects. Mirrors `Config.Tracking`'s existing precedent
(three independently-toggleable flags sharing one file pair, one tick/prune
shape, one config table): all five are structurally the same mechanism (a
0–100 value that rises/falls on triggers and gates behavior at a
threshold), four of the five need Phase 2's existing damage/weapon-fire
relay data as their trigger source (new *consumers*, not new detection),
and the gameplay-facing consequences overlap enough that a *composed*
movement effect (Decision 2) needs to exist regardless. This does **not**
weaken the independent-flag requirement (§3) — enabling `MoodSystem` alone
runs only Mood's own logic; the other four never tick or gate anything.

### Decision 2: a single client-side "move-rate composer" is required once Phase 3 + Phase 4 both exist

By the time both phases ship, **at least four independent features** want
to call `SetPedMoveRateOverride` on the K9's own ped: `PropDragging`
(§12.5.4, already flagged there as needing every-tick reassertion),
`FatigueSystem`'s low-fatigue penalty, `InjuryLimping`'s low-leg-health
penalty, and `XPProgression`'s tier bonus. The native is a **single scalar
override, last-caller-wins** — with no coordination, whichever system calls
it last on a given frame silently cancels every other active modifier, a
guaranteed collision (not a rare race) given `PropDragging`'s own
every-tick reassertion.

**Decision:** one resource-global client function, `RecomputeK9MoveRate()`,
owns the **only** call to `SetPedMoveRateOverride` for the K9's own ped.
Every system sets its own named multiplier in a shared table
(`K9MoveRateModifiers.fatigue`/`.injury`/`.xpTier`/`.dragging`, each
defaulting `1.0`) and calls `RecomputeK9MoveRate()`, which multiplies every
active modifier and makes the one real call. Lives in `client/movement.lua`
(the existing "own body" locomotion file). **Disclosed limitation:** this
prevents modifiers *within this resource* from clobbering each other; it
cannot prevent some *other* resource on the same server from independently
calling the same native and clobbering all of it at once — a pre-existing
FiveM limitation (a single scalar override, global per-entity, no stacking
API) no in-resource coordination can close.

### Decision 3 (methodology, reused from §12.0): "does the client's own claimed stat value matter" is answered the same way every time

Every wellbeing stat, and XP, is **server-authoritative state** — the
server, never the client, owns the real number. But the *movement-speed
consequence* of that state is still a client-self-applied native effect
(Decision 2), the same trust-model category §12.5.5 already accepted for
`AgilityAdvanced`'s own-body locomotion. A modified client could ignore its
own pushed value and never call `RecomputeK9MoveRate()`, giving itself no
penalty a legitimate client would suffer — a real, disclosed, but bounded
limitation: it only ever benefits the cheater's own movement speed (the
same category a server's separate anti-cheat already watches for), and it
never extends to any *server-adjudicated* action — every place a stat or XP
tier gates a real capability (e.g. `FearStress`'s hesitation state
rejecting a combat request server-side) is enforced from the server's own
value, independent of the client's local honesty.

---

## 13.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| 4a — independent | `ContrabandScreenFX` | Pure client-local cosmetic off Phase 2's already-built result. |
| 4b — independent | `K9Inventory` | Self-contained ox_inventory stash, no dependency on wellbeing/XP/medkit. |
| 4c — foundational for 4d/4e/4f | Wellbeing skeleton (no flag of its own) | The shared stat store, tick loop, and `RecomputeK9MoveRate()` (Decision 1/2) — must land before any of the five wellbeing flags is meaningful. |
| 4d — depends on 4c | `FatigueSystem`, `InjuryLimping` | Land together: both are decaying/regenerating stats with only a movement-speed effect through the shared composer. |
| 4e — depends on 4c | `MoodSystem`, `FearStressSystem` | Land together: both react to the same relay-log event class and both gate a *behavioral* effect rather than a pure speed modifier. |
| 4f — depends on 4c and `InjuryLimping` (4d) as a concept | `DistractionSystem` | An instant, event-triggered status effect, not a decay stat — still needs the shared store/tick to expire it. |
| 4g — depends on 4c/4d | `K9Medkit` | Restores real health and the `Injury` stat's tracked value — needs `InjuryLimping`'s stat to exist first. |
| 4h — independent, but its speed effect depends on Decision 2 | `XPProgression` | Award/persistence logic has no wellbeing dependency; sequence after 4c/4d for the speed-multiplier effect. |

## 13.2 Config schema additions

**Every numeric value below is an unreviewed placeholder** (§9 item 4's
scope, widened here) — flagged for a config-validator/economy-balance pass
before any owning flag defaults `true`.

```lua
Config.XP = {
    awards = {
        searchContrabandFound = 25, trackSourceResolved = 10,
        biteHoldSuccess = 20, takedownSuccess = 30,
    },
    scopePerCitizenidOrJob = 'citizenid', -- 'citizenid' (default, portable across dept change) vs 'job' (resets like k9_certifications) -- genuinely open, §13.6 item 2
}

-- Backs FatigueSystem/MoodSystem/FearStressSystem/DistractionSystem/
-- InjuryLimping (Decision 1: one shared table, one file pair, five
-- independently-gated flags).
Config.Wellbeing = {
    tickIntervalMs = 5000, -- ONE shared decay/regen tick for all five stats

    Fatigue = {
        max = 100, sprintDecayPerTick = 2.0, idleRegenPerTick = 1.0,
        restRegenPerTick = 4.0, restRadius = 5.0, restSources = { 'water_bowl' }, -- §13.4.3.1 open question on detection mechanism
        speedPenaltyThreshold = 30, speedPenaltyMultiplier = 0.85, -- fed into RecomputeK9MoveRate(), never a standalone override call
    },
    Mood = {
        max = 100, damageDecayAmount = 15, petRegenAmount = 10, petCooldownMs = 30000,
        feedRegenAmount = 20, feedItemName = 'k9_treat', passiveRegenPerTick = 0.2,
        performancePenaltyThreshold = 25, performancePenaltyMultiplier = 0.9, -- §13.4.3.2 open question: what this multiplies
    },
    FearStress = {
        max = 100, gunfireRadius = 20.0, gunfireLookbackSeconds = 15,
        risePerNearbyShotPerTick = 5.0, passiveDecayPerTick = 1.0,
        hesitationThreshold = 70, hesitationDurationMs = 8000, calmDownReduceAmount = 40, calmDownCooldownMs = 15000,
    },
    Distraction = {
        flashbangImmune = true, -- see §13.4.3.4 -- genuinely integration-dependent, NOT guaranteed
        meatBaitItemName = 'k9_meat_bait', meatBaitDurationMs = 6000, meatBaitRadius = 8.0,
        whistleItemName = 'k9_ultrasonic_whistle', whistleDurationMs = 4000, whistleRadius = 15.0,
        perTargetCooldownMs = 20000,
    },
    Injury = {
        max = 100, sprintBlockThreshold = 30, jumpBlockThreshold = 20,
        speedPenaltyMultiplier = 0.7, damageDecayAmount = 10,
        passiveRegenPerTick = 0.1, -- deliberately slow: K9Medkit is the intended primary recovery path, not natural regen
    },
}

Config.K9Inventory = {
    slots = 5, maxWeight = 8000, interactRange = 2.0,
    accessScope = 'department', -- 'department' (default, shared field equipment) vs 'ownerOnly' -- genuinely open, §13.6 item 3
    allowedItems = nil, -- optional whitelist; enforceability unconfirmed, §13.6 item 3
}

Config.K9Medkit = {
    itemName = 'k9_medkit', healthRestore = 50, injuryRestore = 40,
    range = 2.0, cooldownMs = 60000,
    emsJobs = { 'ambulance' }, -- plus any Config.Departments job
    -- IsMedkitUserAuthorizedOverride: function(usingPlayerServerId) -> boolean, optional
}

Config.ContrabandScreenFX = {
    triggerTiers = { 'aggressive_bark' }, -- which Config.ContrabandAlertTiers alert values also trigger this
    modifierName = 'drug_wobbly_shroom',  -- CANDIDATE ONLY, not independently verified -- §13.4.5
    durationMs = 8000,
}
```

## 13.3 File/module plan

| File | New/extends | Owns |
|---|---|---|
| `server/wellbeing.lua` | New | The unified stat store, the single shared tick loop for all five stats, consumption of Phase 2's existing relay logs (a new *reader*, not a second ingestion copy), `qbx_k9unit:server:getWellbeingSnapshot`, the server-side gate `server/combat.lua` must call before honoring a hesitating K9's combat request. Ephemeral/in-memory, mirroring `server/tracking.lua`'s precedent. |
| `client/wellbeing.lua` | New | Receives pushed snapshots, sets `K9MoveRateModifiers.fatigue`/`.injury` and calls `RecomputeK9MoveRate()`, enforces client-local sprint/jump blocks for low Injury, plays the Distraction effect. |
| `client/movement.lua` | Extends | Adds `RecomputeK9MoveRate()` and `K9MoveRateModifiers` (Decision 2) — the "own body" locomotion file is the right home. Also reserves `.xpTier` and `.dragging` slots for XP and `PropDragging` respectively. |
| `server/progression.lua` | New | XP award/persistence: `K9XP[citizenid]` cache (mirrors `Certifications[citizenid]`), atomic `k9_progression` UPSERT, tier lookup, award hooks into Phase 2/3's success paths. |
| `client/inventory.lua` / `server/inventory.lua` | New pair | `K9Inventory`'s stash open + `RegisterStash`/access-scope enforcement. |
| `client/medkit.lua` / `server/medkit.lua` | New pair | `K9Medkit`'s useable-item registration + server-side heal validation, calling `server/wellbeing.lua`'s `RestoreInjury(citizenid, amount)`. |
| `server/search.lua` | Extends (Phase 2 file) | After computing `alertTier`, if `ContrabandScreenFX` is on and the tier is in `triggerTiers`, sends `applyContrabandScreenFx` to the requester only. |
| `client/search.lua` | Extends (Phase 2 file) | Handles `applyContrabandScreenFx` — `SetTimecycleModifier`, wait, clear; must also clear on resource stop/death/disconnect, mirroring `client/vision.lua`'s exit-path discipline. |
| `config.lua` / `fxmanifest.lua` | Extend | Add §13.2's tables; add the new files. |

## 13.4 — Per-feature detailed spec

### 13.4.1 XP Progression (`Config.Features.XPProgression`)

A configured action (Phase 2 search/tracking success, Phase 3 bite-hold/
takedown success, per `Config.XP.awards`) awards flat XP to the acting K9's
citizenid via an atomic UPSERT, updating the in-memory `K9XP[citizenid]`
cache **synchronously**, before the DB write completes. Crossing a
`Config.XPTiers` threshold immediately changes the server's own
authoritative `scentRange` (read by `findTrackableSource` in place of the
Phase 2 default) and notifies the K9's client to set
`K9MoveRateModifiers.xpTier` (Decision 2). On (re)connect, the server loads
real XP from `k9_progression` into `K9XP`, mirroring `certifications.lua`'s
cache-backfill pattern.

Server-authority: total XP, tier lookup, and resulting `scentRange`/
`speedMultiplier` are 100% server-computed and server-cached — a modified
client claiming a higher tier gets nothing. The speed consequence is a
client-self-applied effect (Decision 3), disclosed and bounded.

Event: `qbx_k9unit:client:xpTierChanged(newTier)` [server→client, K9 only]
on any tier crossing.

Open: (1) per-citizenid or per-(citizenid, job) XP scoping — genuinely open,
§13.6 item 2, blocks `server/progression.lua`'s schema; (2) whether a
separate append-only `k9_xp_log` should exist for audit — not decided; (3)
what exactly counts as "the K9 reached the resolved source" for
`trackSourceResolved` — awarding on `found = true` alone would let XP be
farmed by repeatedly triggering searches without completing them; a fix
(server verifies live arrival proximity before awarding) is sketched, not
committed; (4) award values/tier thresholds remain unreviewed placeholders
(§9 item 4).

### 13.4.2 K9 Inventory (`Config.Features.K9Inventory`)

On `PlayerLoaded` (or lazily), the server registers a per-character stash
(`'k9inv-' .. citizenid` — one per K9 character, **keyed to the K9 player's
own citizenid**, correcting §6.5's leftover pre-correction "handler's active
K9 slot" phrasing, which doesn't exist in this resource's model). An
ox_target option opens it via the standard ox_target + ox_inventory
pattern, subject to `slots`/`maxWeight`/`allowedItems`.

Server-authority: stash access is a real ox_inventory-enforced capability —
the `owner`/`groups` arguments at `RegisterStash` time are what actually
restrict access; the ox_target option's visibility is a UX convenience
only. The stash id is derived server-side from the K9's own resolved
citizenid, never client-supplied.

Open: (1) `accessScope` department-shared vs. owner-only — a real
product/security-posture fork, not a formality (§13.6 item 3); (2)
`allowedItems` enforceability — no native ox_inventory whitelist-at-registration
option is confirmed to exist; would need a `registerHook`-style item-move
hook if not; (3) exact dynamic per-player `RegisterStash` call shape not
independently verified against source/a live install; (4) whether opening
the stash should require a "safe" (non-leashed/non-combat) K9 state — a
judgment call, not a mandate.

### 13.4.3 K9 Wellbeing — unified subsystem

Per Decision 1, the five flags below are documented as instances of one
mechanism.

#### 13.4.3.1 Fatigue (`Config.Features.FatigueSystem`)

The shared tick decrements `fatigue` by `sprintDecayPerTick` while
server-computed recent-position-delta speed indicates sprinting (reusing
§12.5.2's exact rolling-sample technique, a second consumer not a new
detection method), increments by `idleRegenPerTick` otherwise or
`restRegenPerTick` within `restRadius` of a rest source. Below
`speedPenaltyThreshold`, the client sets the fatigue move-rate modifier
(Decision 2). Open: exact rest-source detection mechanism (item name?
world-object proximity? both) — should stay extensible since Phase 5's
kennel will likely also want to be a rest source; whether Fatigue should
also gate a Phase 3 combat action (recommend not, without an explicit ask).

#### 13.4.3.2 Mood (`Config.Features.MoodSystem`)

Decrements by `damageDecayAmount` on a logged damage event where the K9 is
the victim (a second, independent consumer of Phase 2's relay, not a change
to what `server/tracking.lua` does with it); increments via "Pet K9"
(`petRegenAmount`, `petCooldownMs`) or a configured food item
(`feedRegenAmount`); passively regenerates otherwise. Below
`performancePenaltyThreshold`, a "minor performance penalty" applies.
**Open (real fork, not a naming quibble):** what exactly the penalty
applies to — (a) a movement-speed multiplier through the same composer as
Fatigue/Injury (simplest, tentatively recommended), or (b) a success-chance
penalty on Phase 2/3 rolls (a materially bigger change, requiring a new
parameter into already-designed security-critical callbacks). Not decided
here. Also open: whether petting requires the interactor to hold a
`Config.Departments` job, or is open to any nearby player.

#### 13.4.3.3 Fear/Stress (`Config.Features.FearStressSystem`)

Rises by `risePerNearbyShotPerTick` per tick for each weapon-fire event in
Phase 2's existing log within `gunfireRadius`/`gunfireLookbackSeconds` —
the cleanest reuse in the subsystem, zero new detection mechanism. Above
`hesitationThreshold`, the K9 enters a hesitation state for
`hesitationDurationMs` — a real, **server-enforced** refusal of Phase 3's
`BiteAndHold`/`NonLethalTakedown`/`PropDragging` requests, until "Calm Down"
(`calmDownReduceAmount`, `calmDownCooldownMs`) or natural decay.

**The one wellbeing stat with a real, not cosmetic, server-enforced gate:**
unlike Fatigue/Injury's speed-only consequence, `server/combat.lua` must
call a `server/wellbeing.lua`-exposed `IsHesitating(citizenid) -> boolean`
as a pre-check in its own request validation — a modified client ignoring
its own pushed `fearStress` value and firing a request anyway must still be
rejected server-side.

Open: whether the hard-timeout-then-retry shape is right vs. requiring
explicit "Calm Down" every time; whether "Calm Down" should be self-only
(this document assumes self-only, an interpretation not a certainty) or
issuable by a partnered handler on someone else's K9. **See `OPERATOR_RUNBOOK.md`'s
D13 for the still-open, repeatable-griefing angle on this stat.**

#### 13.4.3.4 Distraction (`Config.Features.DistractionSystem`)

Two independent halves. **Item-triggered distraction** (fully native-only):
a thrown "meat bait" or used "ultrasonic whistle" item, within its radius
of one or more K9-model players, sets `distractedUntil` server-side per
affected K9 (subject to `perTargetCooldownMs`) — interpreted as a rejection
of Phase 3 combat-command requests server-side, not a forced animation (the
same non-possession principle as §12.0 item 2). **Flashbang immunity**
(genuinely integration-dependent, **not** guaranteed native-only): flashbang
effects typically come from a separate, server-specific weapon resource,
not one vanilla native this resource can intercept generically — whether
immunity is achievable at all depends on how that other resource applies
its stun effect, which this document cannot responsibly guess at. Ships as
aspirational config pending an ecosystem-verification pass, not a
guaranteed deliverable.

Server-authority: item-triggered distraction is a real capability with real
stakes (could plausibly be used *against* a pursuing K9 by a fleeing
suspect) — the server resolves affected K9s from the using player's own
live position, never a client-claimed target, and consumes the item
server-side via ox_inventory.

Open: flashbang immunity's actual achievability; whether using the item
should require any particular job/permission or be open to anyone
(including, plausibly, an adversarial suspect) — reading the original
wording as intentionally open, not asserted as certain.

#### 13.4.3.5 Injury/Limping (`Config.Features.InjuryLimping`)

Decrements by `damageDecayAmount` per logged damage event (same relay reuse
as Mood), regenerates very slowly passively — `K9Medkit` is the intended
primary recovery path, not natural regen. Below `sprintBlockThreshold`/
`jumpBlockThreshold`, the relevant input is blocked
(`DisableControlAction`, the same mechanism `AgilityBasicJump`'s
suppression thread already uses); below either, the composer applies
`speedPenaltyMultiplier`. Server-authority: the `injury` value is
server-tracked; the sprint/jump input blocks are **client-local,
self-applied, not separately server-enforced** — a modified client ignoring
its own low-injury value gains only the same bounded, self-contained
movement advantage every other wellbeing stat's speed effect does (Decision
3).

### 13.4.4 K9 Medkit (`Config.Features.K9Medkit`)

A player holding a `Config.Departments`/`emsJobs` job uses the configured
item on a nearby K9 to restore `healthRestore` to real ped health and
`injuryRestore` to the wellbeing `Injury` value, subject to `cooldownMs`.

**Reality check, honestly flagged:** `SetEntityHealth` restoring a networked
ped's health from server-side script is standard, widely-used FiveM
practice, but was **not independently verified against this codebase's own
natives-research convention** — MEDIUM confidence, not asserted at the same
certainty as e.g. `SetSeethrough`. The recommended, more-consistent-with-
this-codebase's-own-precedent alternative is a `applyMedkitHeal` event to
the target K9's **own** client, which calls `SetEntityHealth` on itself —
same "client self-applies to its own entity" pattern used throughout this
phase — but this is a recommendation, not confirmed necessary; verify
before committing to either approach.

Server-authority, mirroring §15 `#contraband-search`'s established pattern:
(1) feature-flag + eligibility first, (2) **live proximity check before any
state mutation**, never a client-claimed distance — closes the single most
important "map-wide oracle" risk that note flags, applied here to a heal
effect instead of an inventory read, (3) target-type re-verified
server-side via `GetEntityModel`, (4) item consumption is
server-authoritative via ox_inventory (exact export/registration pattern
not independently verified this session — same caveat class as §9 item
11), (5) cooldown stamped **before** the heal completes, not after, (6)
restoration clamped to each value's own max, never allowed to overheal.

Open: `SetEntityHealth`'s server-vs-client reliability (the single biggest
open implementation question here); exact ox_inventory useable-item
registration API; `emsJobs`'s relationship to whatever real EMS system the
target server runs (a plausible shape, not a confirmed export); whether
treating a K9 should require the K9's own consent (mirrors leash) or not
(mirrors human medkit revives, which typically don't need the downed
player's consent) — this document leans toward **no consent required**, by
analogy to human medical treatment, flagged as an interpretive choice
between two established precedents in this codebase, not an obviously
correct pick.

### 13.4.5 Contraband Screen FX (`Config.Features.ContrabandScreenFX`)

When Phase 2's `searchTarget` resolves an `alertTier` in `triggerTiers`,
the **requesting K9's own client only** (never a broadcast) gets
`SetTimecycleModifier(modifierName)` for `durationMs` — a "contact high"
from close-proximity exposure during a search.

**Genuine open uncertainty, not resolved with false confidence:**
`modifierName = 'drug_wobbly_shroom'` is a **candidate only** (chosen by
family resemblance to GTA's drug-effect timecycle modifiers), unlike
`SetSeethrough`/`SetNightvision` which two independent passes confirmed
against real evidence — no equivalent verification exists for this string.
Needs a native/asset-data verification pass before implementation.

Server-authority: purely cosmetic, self-applied, no new trust surface — the
`alertTier` value it keys off is already 100% server-computed upstream by
`searchTarget`.

Open: exact modifier string; which tiers should trigger this (defaults to
only the most severe, a severity judgment call, not dictated by the
original wording); whether this should also apply to `K9Inventory`
interactions with contraband-adjacent items (out of scope as read here).

---

## 13.5 Cross-cutting notes carried forward to §9

- §9 item 4 widens to cover every numeric value in `Config.XP.awards`,
  `Config.Wellbeing`, `Config.K9Inventory`, `Config.K9Medkit`, and
  `Config.ContrabandScreenFX` — the scope of that item widens, it doesn't
  get a duplicate.
- **Cross-phase dependency:** `server/combat.lua` must call
  `server/wellbeing.lua`'s `IsHesitating(citizenid)` (§13.4.3.3) as part of
  its own request-validation order.
- **Shared-infrastructure requirement:** `RecomputeK9MoveRate()` (Decision
  2) must exist before Phase 3's `PropDragging` and any of this phase's
  speed-affecting features ship together.
- Every ox_inventory export/registration pattern this phase relies on
  beyond what §15 `#contraband-search` already confirmed (dynamic
  per-player `RegisterStash`, useable-item registration, any
  whitelist-enforcement hook) is unverified against real source or a live
  install.
- Flashbang immunity's integration dependency (§13.4.3.4) joins door-lock
  nudge-open (§9 item 12) as the second feature whose native-only
  feasibility is conditioned on an unconfirmed third-party resource.

## 13.6 — Quick-reference: decisions

1. Decision 1 (unify five flags into one subsystem) and Decision 2 (single
   move-rate composer) — both **decided**, following this codebase's own
   `Config.Tracking` precedent.
2. **XP scoping: per-citizenid or per-(citizenid, job)?** — genuinely open,
   blocks `server/progression.lua`'s schema.
3. **`K9Inventory.accessScope`: department-shared or owner-only?** —
   genuinely open, blocks the `RegisterStash` `owner`/`groups` arguments.
4. **Mood's "performance penalty" mechanism** — genuinely open, a real fork
   between a speed multiplier and a heavier change to security-critical
   Phase 2/3 callbacks.
5. **Flashbang immunity's actual achievability** — genuinely open, an
   unconfirmed third-party integration dependency.
6. **`SetEntityHealth`'s server-vs-client reliability for `K9Medkit`** —
   genuinely open, needs a native-verification pass.
7. **ox_inventory export/registration signatures** for dynamic stashes and
   useable items — genuinely open, needs verification against real source.
8. **Every numeric placeholder in §13.2** needs a config-validator/
   economy-balance pass before any of the nine flags in this phase's scope
   defaults to `true`.

---

## 14.0 — Cross-cutting design forks: resolved before any per-feature spec assumes an answer

### Fork 1 — the bone-index dependency (blocks `PropAttachments` and half of `FetchMechanic`)

**Resolved as a bounded, one-time engineering task, not a design decision
left open.** `AttachEntityToEntity`'s bone-index parameter accepts a raw
integer either way — a documented bone *name* was never actually
load-bearing, only convenient. `GetWorldPositionOfEntityBone` is
entity-type-agnostic and works on any raw index regardless of whether a
name is documented for it, converting "find a documented animal-skeleton
bone name" (a task every accessible source has failed at) into "find a
usable numeric index by direct in-engine observation" (completable in one
dev-server sitting).

**Procedure:** a throwaway `dev/bone_sweep.lua` (never added to
`fxmanifest.lua`, deleted/excluded after use) spawns/rides each
`Config.Peds` model in turn (skeleton consistency across breeds is **not**
confirmed, so all four are swept independently), loops bone index 0–199
calling `GetWorldPositionOfEntityBone` and drawing a marker + label per
index (no confirmed sentinel value distinguishes "real" from "invalid" for
this native — visually inspect all 200, don't auto-filter), and a developer
records, per model, a neck/shoulder/back index (`vestBoneIndex`) and a
mouth/jaw index (`mouthBoneIndex`) into `Config.K9BoneIndices`. While
finding the mouth index, also trigger the existing `WORLD_DOG_BARKING_*`
scenario with a test prop attached and watch for clipping — the one extra
check the mouth-carry case needs that the vest case doesn't. If no bone
distinctly separate from root/spine is found for a model, record `nil`
rather than a guess — see §14.4.2/§14.4.3 for each feature's disclosed
fallback. This sweep is a single dev-server task that unlocks both features
at once — not scheduled twice. **The shipped implementation of this
sweep is `client/bonetool.lua`/`server/bonetool.lua`, run via
`Config.Features.BoneSweepDevTool` — see `OPERATOR_RUNBOOK.md` §2b/§4 for
how to run it and why it must be turned back off afterward.**

### Fork 2 — `ProximityAudioFX`'s missing "hidden suspect" detection primitive

**Resolved: do not build a new live-entity "is this ped hidden" detection
primitive in this pass.** Ship the buildable half (audio delivery) fully
working, with the trigger condition exposed as an explicit, disclosed,
`nil`-by-default integration hook — the same "we cannot resolve this
ourselves, here is the seam" pattern already used twice in §12.0 (items 5,
6). This resource's one existing "find something near the K9" mechanism
(`findTrackableSource`) resolves the nearest still-fresh **logged
coordinate** — a historical event location, pull-based, not a live entity's
continuously-updating position — and no "is this ped currently
hidden/crouching" concept exists anywhere in this codebase. Building one is
genuine, undersized-by-the-original-wording design and implementation work,
not a natives-availability gap.

**Considered and explicitly rejected:** reusing an active tracking trail's
resolved coordinate as a stand-in "suspect" distance target. Rejected
because it's a static historical point, not a live fleeing suspect, and it
would only ever apply while a Phase 2 tracking flag is also on.

**Resolution:** `Config.ProximityAudioFX.SuspectDistanceSource` —
`function() -> number?`, `nil` by default, evaluated client-side on a tick.
Must return the live distance to whatever *this server's own* hidden-suspect
concept considers relevant, or `nil`. There is no ecosystem-dominant
convention to guess at here — **no default implementation at all, only the
seam.** While `nil` (the shipped state), the feature is real, wired, and
inert. Flipping the feature flag on without ever wiring the hook is not a
bug.

### Fork 3 — asset dependency: what ships working with zero assets vs. what needs an operator to supply something

| Feature | Zero-asset? | What an operator must supply |
|---|---|---|
| `ProximityAudioFX` | Audio mechanism: yes (same safe placeholder-soundset convention as `BasicBarkSounds`). Trigger condition: no — inert until `SuspectDistanceSource` is wired (fork 2). | Real growl/pant audio (already shipped as `.ogg`, see `README.md`), and a `SuspectDistanceSource` implementation. |
| `PropAttachments` | No — unlike `DeployableKennel`, no research pass found any generically-real placeholder prop for a quadruped vest/harness. | A real prop model name — `propModel` ships `nil`, the feature safely no-ops (one log line) until an operator sets it. |
| `FetchMechanic` | Yes, for the ball itself — `prop_tennis_ball` is the highest-confidence prop name found. Mouth-*carry* fidelity is conditional on fork 1. | Nothing required for a working feature. Optionally a custom "evidence bag" prop reskin (not required for v1). |

### Fork 4 (smaller, but load-bearing for §14.2/§14.3) — where does `ProximityAudioFX`'s automatic growl-relay cooldown live?

**Resolved: a brand-new event and cooldown table, not a reuse of
`relayBark`'s** — mirrors `relayDoorScratch`'s own already-established
precedent of not sharing `BarkCooldown` with an unrelated action. The
growl fires automatically and repeatedly (potentially every ~800ms at the
closest tier); sharing `relayBark`'s 1000ms floor would silently starve
either action purely as an artifact of budget-sharing. Gets its own event
(`relayGrowl`), cooldown table, and length cap.

---

## 14.1 Sub-phase ordering (dependency graph)

| Sub-phase | Feature(s) | Why this order |
|---|---|---|
| 5a — independent | Fork 1's bone-index sweep (throwaway) | Blocks 5c and half of 5d; cheap, bounded, unlocks two features at once. |
| 5b — independent, parallel with 5a | `ProximityAudioFX` | Unrelated to bone attachment; ships inert until `SuspectDistanceSource` is wired. |
| 5c — depends on 5a | `PropAttachments` | The attach mechanism needs zero new research (already proven, `client/vehicle.lua`); blocked only on 5a's recorded index existing. |
| 5d — spawn/throw/lifecycle independent of 5a; mouth-carry depends on 5a | `FetchMechanic` | The ball's lifecycle can start immediately with `mouthCarryModeByModel` defaulted to `'fake'`. |

## 14.2 Config schema additions

**Every numeric value below is an unreviewed placeholder** — none of these
three flags default `true`.

```lua
-- Populated ONLY by running dev/bone_sweep.lua (throwaway, not shipped)
-- against each Config.Peds model. nil = "sweep not yet run for this model" --
-- each consuming feature has its own documented fallback, never a guess.
Config.K9BoneIndices = {
    a_c_shepherd   = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_rottweiler = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_husky      = { vestBoneIndex = nil, mouthBoneIndex = nil },
    a_c_chop       = { vestBoneIndex = nil, mouthBoneIndex = nil },
}

-- Fallback offset from bone index 0 (root), used only when a model's
-- Config.K9BoneIndices entry above is still nil.
Config.K9BoneFallbackOffsets = {
    vest  = { x = 0.0, y = 0.15, z = 0.35 },
    mouth = { x = 0.0, y = 0.45, z = 0.15 },
}

Config.ProximityAudioFX = {
    tickMs = 1000,
    SuspectDistanceSource = nil, -- function() -> number?, optional, no default implementation exists -- fork 2
    distanceTiers = {
        { maxDistanceMeters = 5.0,  growlType = 'growl_close', cadenceMs = 800 },
        { maxDistanceMeters = 12.0, growlType = 'growl_near',  cadenceMs = 1500 },
        { maxDistanceMeters = 25.0, growlType = 'growl_far',   cadenceMs = 2500 },
    },
    serverCooldownMs = 500, -- own cooldown, independent of BarkCooldown -- fork 4
}

Config.PropAttachments = {
    {
        id = 'vest', label = 'Equip/Unequip Vest', icon = 'vest',
        propModel = nil, -- OPERATOR-SUPPLIED -- feature safely no-ops while nil, §14.4.2
        boneField = 'vestBoneIndex',
    },
}

Config.FetchMechanic = {
    ballPropModel = 'prop_tennis_ball',
    throwForwardOffsetMeters = 1.0, throwUpOffsetMeters = 1.2,
    throwForceForward = 12.0, throwForceUp = 6.0,
    throwCooldownMs = 5000, pendingThrowTtlMs = 15000,
    maxBallLifetimeMs = 300000,
    pickupInteractDistanceMeters = 2.0,
    mouthCarryModeByModel = {
        a_c_shepherd = 'fake', a_c_rottweiler = 'fake', a_c_husky = 'fake', a_c_chop = 'fake',
    },
}
```

## 14.3 File/module plan

| File | New/extends | Owns |
|---|---|---|
| `dev/bone_sweep.lua` | New, throwaway | Fork 1's raw-index sweep. Not added to `fxmanifest.lua`. |
| `client/proximityaudio.lua` | New | `ProximityAudioFX`'s tick loop, evaluating `SuspectDistanceSource()`, picking a tier, sending `relayGrowl`; also the receiving `playGrowl` handler. |
| `server/main.lua` | Extends | `relayGrowl` handler — a near-identical sibling of `relayBark`, own cooldown table/length cap (fork 4). |
| `client/main.lua` | Extends (small) | New exported `CanActAsK9Handler() -> boolean` — needed because `FetchMechanic`'s "Throw" is a **human handler** action, not necessarily a K9-riding player. |
| `client/attachments.lua` | New | `PropAttachments`'s entire implementation: one radial item per configured slot, tracked local object handles, unequip on model swap/disconnect/`onResourceStop`. **No server file** — see §14.4.2's trust-model decision. |
| `client/radial.lua` | Extends (small) | An "Equipment" submenu opener, and a "Throw Fetch Ball" item gated via `CanActAsK9Handler()`. |
| `client/fetch.lua` / `server/fetch.lua` | New pair | `FetchMechanic`'s full lifecycle, modeled on `client/kennel.lua`/`server/kennel.lua`'s spawn/confirm/cleanup pattern. |
| `config.lua` / `fxmanifest.lua` | Extend | Add §14.2's tables; add the new files. `dev/bone_sweep.lua` is never added to the manifest. |

## 14.4 — Per-feature detailed spec

### 14.4.1 Proximity Audio FX (`Config.Features.ProximityAudioFX`)

Requires `BasicBarkSounds` also `true`. A tick loop evaluates
`SuspectDistanceSource()`; if `nil` or beyond the farthest tier, nothing
happens. Otherwise it finds the nearest-matching tier and, once that tier's
own `cadenceMs` has elapsed, sends `relayGrowl(growlType)`. The server
re-validates flags/access, length-caps `growlType`, consumes the
independent `GrowlCooldown`, resolves the sender's own ped (never
client-supplied), and broadcasts `playGrowl(netId, growlType)` to everyone
— the same "broadcast wide, let native audio 3D-cull" posture as
`relayBark`/`relayDoorScratch`.

Open: the real "hidden suspect" detection primitive itself (explicitly
deferred, fork 2).

### 14.4.2 Prop Attachments (`Config.Features.PropAttachments`)

A config-driven list of "slots," each its own context-sensitive
Equip/Unequip radial item under an "Equipment" submenu. **Self-administered,
purely client-side, zero new server event — a deliberate decision.**
Extends `client/vehicle.lua`'s own already-shipped, already-accepted
precedent — deliberately **not** `DeployableKennel`'s pattern (full
server-computed-coords + registry), because a worn prop has no independent
existence, it lives and dies exactly with the K9's own ped.

On Equip: resolves the model's `Config.K9BoneIndices` entry and attaches via
`AttachEntityToEntity`; if unresolved, falls back to root bone + the
documented fallback offset; if `propModel` is `nil`, notifies "not
configured" and does nothing. On Unequip: `DetachEntity` + `DeleteEntity`,
also on model swap, K9 vehicle entry/exit, disconnect, and
`onResourceStop`. **Disclosed limitation:** no server-side re-check forces
an unequip on later decertification — mirrors `client/vehicle.lua`'s own
existing "no forced eject" posture.

Open: the real prop model(s) (fork 3, operator-supplied); whether nested
attachment (prop on a K9 that then enters a vehicle) renders correctly —
untested.

### 14.4.3 Fetch Mechanic (`Config.Features.FetchMechanic`)

**Throw** (a *handler* action — the thrower need not be K9-riding): radial
item gated by `CanActAsK9Handler()`. Server re-validates flag/access/
cooldown/one-active-ball-per-thrower, computes a spawn point + throw-force
vector from the thrower's own live position/forward vector. **Pursue:**
zero scripting — normal native locomotion, no autonomous pursuit task.
**Pick up:** within `pickupInteractDistanceMeters`, an ox_target option
gated by `CanShowK9UI()`, server re-validated. **Carry:** branches on
`mouthCarryModeByModel[currentModel]` — `'attach'` (only for a model whose
sweep found a usable index) does a one-shot `AttachEntityToEntity` at the
mouth bone (deliberately **not** re-asserted every tick, unlike
`PropDragging` — no adversarial party); `'fake'` (the default for every
model) deletes the world ball and plays a carry animation/scenario
instead. **Drop:** a second radial toggle releases wherever the K9 stands.
**Lifecycle:** `maxBallLifetimeMs` force-despawns an un-dropped ball;
`playerDropped`/`onResourceStop` cleanup mirrors `server/kennel.lua`'s
pattern.

Open: whether `'fake'` mode's animation should reuse the existing
`WORLD_DOG_BARKING_*` scenarios (untested for this intent); fork 1's sweep
outcome per model.

---

## 14.5 — Cross-cutting notes carried forward

- Config-validator pass required before any of these three flags default
  `true` — every numeric value in §14.2 is an unreviewed, reasonable-looking
  guess.
- `SuspectDistanceSource` and `propModel` are both, deliberately,
  "we cannot resolve this ourselves, here is the seam" integration points,
  not partially-implemented features.
- `ProximityAudioFX` is specced against the existing, proven
  `PlaySoundFromEntity` pipeline, reusing `relayBark`'s shape almost
  verbatim.

## 14.6 — Quick-reference: decisions

1. Fork 1 (bone-index sweep) — **resolved** as a concrete, bounded
   procedure; shipped as `client/bonetool.lua`/`server/bonetool.lua`.
2. Fork 2 (`ProximityAudioFX`'s hidden-suspect detection) — **resolved** as
   a deliberate deferral: delivery ships real; the trigger ships as an
   inert, `nil`-by-default hook.
3. Fork 3 (asset dependency) — **resolved** as an explicit per-feature
   disclosure.
4. Fork 4 (`ProximityAudioFX`'s cooldown) — **resolved**: a new,
   independent event/cooldown pair.
5. `PropAttachments`' trust model — **resolved**: purely client-side, no
   server event. Disclosed limitation: no forced unequip on later
   decertification.
6. `FetchMechanic`'s throw-gate — **resolved**: `CanActAsK9Handler()`,
   distinct from `CanShowK9UI()`.
7. `FetchMechanic`'s mouth-carry fidelity — **resolved as a safe default**:
   every model ships `'fake'` until a sweep + clipping check explicitly
   upgrades a specific model.
8. Real growl/pant/vest/harness/camera-housing audio and prop assets — bark
   and growl audio shipped (see `README.md`); vest/harness props remain
   operator-supplied (fork 3).
