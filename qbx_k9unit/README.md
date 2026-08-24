# qbx_k9unit

Player-controlled K9 unit for Qbox police/security departments.

The K9 is **a player's own persistent character** — someone creates their
character as a dog ped (German Shepherd, Rottweiler, Husky, Chop, or any
other model you add to `Config.Peds`) through your server's normal
character-creation flow, gets hired into a K9-eligible department through
your normal job-hiring flow, and is then **certified** by a qualifying
officer using this resource. This resource does **not** spawn, despawn, or
possess a ped on anyone's behalf, and there is no "select a K9 from a menu"
concept anywhere in it — certification is purely an access-control layer on
top of a player who is already playing as a dog.

**Status:** Phase 1 (vertical slice) is feature-complete and reviewed:
certification grant/revoke/check, a consensual two-player leash system,
the "K9 Unit" radial menu, K9 vehicle load/release, and a bark relay.
**Phase 2 (tracking, search zones/contraband alerts, vision, door
interaction) is implemented and has been through security/QA/regression/
correctness review passes** — see
[Phase 2 configuration](#phase-2-configuration-not-enabled-by-default)
below for every option it adds. Its source files (`client/tracking.lua`,
`client/search.lua`, `client/vision.lua`, `server/tracking.lua`,
`server/search.lua`, plus door interaction, which was folded into the
existing `client/movement.lua`/`server/main.lua` rather than getting its
own file) contain real, reviewed logic now, not scaffolding. **None of it
is active on an existing install by default**, though: every Phase 2
`Config.Features` flag (`BloodTracking`, `GunpowderSniffing`,
`ScentTracking`, `WaterTrackingDecay`, `SearchZones`, `ContrabandAlerts`,
`ThermalVision`, `NightVision`, `DoorInteraction`) still ships `false` —
nothing changes until a server owner deliberately opts in, flag by flag.
`Config.Features.ScentTracking`'s server-side trail-source resolution
(`server/tracking.lua`, backed by a real `ox_inventory` `swapItems` hook)
was implemented this pass — see `SPEC.md` §9 item 17 and
`phase2_notes/scent_source_resolution.md` for the confirmed mechanism.
It is no longer a hard "can never functionally succeed" exception, but it
is also not yet cleared for the same unconditional "safe to enable" status
as the rest of Phase 2: the ox_inventory hook's exact payload
shape/behavior was confirmed by direct source-reading, not by an
independent test against a live install, so a one-time dev-time
verification is recommended before enabling on a production server — see
`CHANGELOG.md`'s Known Limitations section for the exact residual caveat.
Every other Phase 2 flag is implemented, reviewed, and safe to enable once
you've read its config section below. Door interaction now ships **both**
scratch-to-alert and nudge-open — see
[Config.DoorInteraction](#configdoorinteraction) below for nudge-open's
deliberately cosmetic-only safety design.

**Phase 4 (inventory, progression, vitality)** now has real code behind
several still-`false` flags, not just the vitality HUD: a passive vitality
HUD (`client/hud.lua`, `Config.Features.HealthStaminaHUD`), a per-K9
`ox_inventory` gear stash (`Config.Features.K9Inventory`), a
server-authoritative K9 medkit (`Config.Features.K9Medkit`), a unified
Fatigue/Mood/FearStress/Distraction/Injury wellbeing subsystem
(`Config.Features.FatigueSystem`/`MoodSystem`/`FearStressSystem`/
`DistractionSystem`/`InjuryLimping`), and XP/progression
(`Config.Features.XPProgression`) — see
[Phase 4 configuration](#phase-4-configuration-not-enabled-by-default)
below for all of it. Only `Config.Features.ContrabandScreenFX` remains a
Phase 4 flag with no code behind it.

**Phase 5 (audio/props/camera R&D)** also has its first two real
implementations: a deployable kennel R&D scaffold
(`Config.Features.DeployableKennel`) and an advanced bark radial
(`Config.Features.AdvancedBarkRadial`, which adds three more placeholder
sound names with no real audio behind them — see
[Bark sounds are placeholders](#bark-sounds-are-placeholders) below). See
[Phase 5 configuration](#phase-5-configuration-not-enabled-by-default) for
both. `Config.Features.ProximityAudioFX`, `PropAttachments`,
`FetchMechanic`, and `CameraFeedPiP` remain uncoded — a research pass
(`phase2_notes/phase5_remaining_features_research.md`) reframed, but did
not close, the first two: `ProximityAudioFX`'s real blocker turns out not
to be its audio (buildable on this resource's existing NUI bridge) but the
complete absence of any "hidden suspect" detection primitive anywhere in
this codebase — Phase 2's tracking system resolves a static, logged
coordinate, never a live entity's current position; `PropAttachments` (and
`FetchMechanic`'s identical mouth/jaw attach point) no longer need a
documented bone *name*, only a bone *index*, obtainable via a short
in-engine sweep — a bounded engineering task now, not indefinitely-blocked
research.

**Phase 3 (combat/action features)** now has all four of its combat/
agility mechanics fully implemented, and all three combat mechanics are
reachable through this resource's own UI: `BiteAndHold`, `NonLethalTakedown`,
and (newly) `PropDragging` are registered in `server/combat.lua` +
`client/combat.lua` and wired into `fxmanifest.lua`, alongside
`AgilityAdvanced`, fully implemented behind its still-`false` flag
(`client/movement.lua`). The "K9 Unit" radial menu now exposes "Bite & Hold
/ Release", "Non-Lethal Takedown", and "Drag / Release" items — the
previously-disclosed "code exists but nothing can trigger it" gap is
closed. `PHASE3_SPEC.md`'s design scoping has also moved forward — a
reversal puts player-vs-player K9 combat in scope, and the two
cross-cutting design forks that were blocking implementation (the
client-relay/non-cooperating-target-client architecture, and which officer
counts as a given K9's "handler" independent of leash state) have both
been resolved as design decisions. The handler-partnership resolution — a
new, dedicated **partnership registry**, not a reuse of the existing leash
pairing — has now been **implemented** too:
`Config.Features.HandlerPartnership` (still `false` by default) gates a
mutually-consented "Partner Up"/"Break Partnership" handshake
(`server/partnership.lua` + `client/partnership.lua`), DB-backed so it
survives a disconnect or resource restart, unlike leash. **This is a
foundation only** — `HandlerDownDefense` and `PHASE3_SPEC.md`'s Recall
mechanic, the two features this registry exists to unblock, both still
have **zero code**; the registry unblocks building them, it does not
deliver either. A disclosed gap in the registry as shipped: nothing
re-syncs a reconnecting client's own view of an already-established
partnership, so `IsPartnered()`/`GetPartnerServerId()` can under-report
until a fresh consent-handshake event reaches that client — see
[Config.Features.HandlerPartnership](#configfeatureshandlerpartnership)
below.

Completing `client/combat.lua` earlier found and fixed a real safety bug:
`SetEntityCanBeDamaged` is confirmed client-only, so `NonLethalTakedown`'s
NPC-target branch calling it server-side was a silent no-op — a
"non-lethal" takedown against an NPC could actually kill it before that
fix. Landing `PropDragging` and the combat radial items found two more real
gaps: `NetworkRequestControlOfEntity` had never been requested before
driving natives against an NPC target this K9's own client doesn't already
control, which could have made the earlier `NonLethalTakedown` safety fix
silently no-op again on a populated server (now requested every tick,
best-effort); and `client/combat.lua` had no `onResourceStop` handler
despite setting several persistent native flags, risking a permanently
undamageable player or permanently flee-suppressed NPC across a resource
restart mid-effect (now fixed). Separately, a security review found every
one of `client/combat.lua`'s event handlers had been registered
**unconditionally**, so any connected player could trigger effects like
indefinite self-invincibility via a locally-forged event with **zero
server contact, even with every one of `BiteAndHold`/`NonLethalTakedown`/
`PropDragging`'s flags `false`** — this resource's false-by-default
posture gave no actual protection there. Handlers are now gated
per-mechanic, restoring genuine inertness when a given mechanic is off.
**This does not close the deeper client-relay trust boundary**: once a
mechanic *is* enabled, none of its handlers verify a given event actually
came from the server rather than a local self-trigger — that remains a
separate, still-open item for a dedicated security pass, not something the
per-mechanic gating fix resolves. Do not enable `Config.Features.BiteAndHold`,
`NonLethalTakedown`, `PropDragging`, or `HandlerDownDefense` — see
`CHANGELOG.md`'s Known Limitations for the full detail.

## Dependencies

Install and **start these before** `qbx_k9unit` (declared in
`fxmanifest.lua`'s `dependencies` block):

| Resource | Source | Notes |
|---|---|---|
| [`qbx_core`](https://github.com/Qbox-project/qbx_core) | Qbox-project | Player data, jobs, `GetPlayer`/`GetPlayerByCitizenId` exports, `QBCore:Server:OnJobUpdate` / `QBCore:Server:PlayerLoaded` events |
| [`ox_lib`](https://github.com/overextended/ox_lib) | overextended | `lib.callback`, `lib.notify`, `lib.alertDialog`, `lib.addRadialItem` |
| [`ox_target`](https://github.com/overextended/ox_target) | overextended | In-world interaction options (leash, certify/revoke, vehicle load) |
| [`oxmysql`](https://github.com/overextended/oxmysql) | overextended | Database access for the certification table |
| [`ox_inventory`](https://github.com/overextended/ox_inventory) | overextended | **Phase 2** (`server/search.lua`) — reads a searched vehicle's/person's real inventory contents and live item weights for the contraband-search feature, supporting `Config.Features.SearchZones`/`ContrabandAlerts`. Also used by three **Phase 4** features, all still `false` by default: `Config.Features.K9Inventory` (`RegisterStash`/`openInventory` for the K9 gear stash), `Config.Features.K9Medkit` (`GetItemCount`/`RemoveItem` to consume the medkit item), and the wellbeing subsystem's Mood/Distraction stats (`Config.Features.MoodSystem`/`DistractionSystem`, same two exports, for feed/meat-bait/whistle item consumption). Still required to be **started** (declared in `fxmanifest.lua`'s `dependencies`) even while every one of those flags is `false`. |

Qbox/QBCore data model only — there is no ESX support.

## Installation

1. Drop `qbx_k9unit` into your server's `resources` folder.
2. **Run the SQL migration before first start.** Import
   `qbx_k9unit/sql/install.sql` against your database with your usual DB
   client (phpMyAdmin, HeidiSQL, the `mysql` CLI, etc.) — this resource does
   not auto-execute it. It creates `k9_certifications` (see
   [Database](#database) below), `k9_search_log` (Phase 2 search audit
   trail), `k9_partnerships` (schema landed ahead of its own
   implementation — no code reads or writes it yet, see
   [Database](#database)), and `k9_progression` (Phase 4 XP persistence —
   see [Database](#database); this table was missing from earlier drafts
   of this migration, so no K9's XP ever actually survived a restart
   before it was added). All four are idempotent
   (`CREATE TABLE IF NOT EXISTS`) if you accidentally run it twice or are
   applying it to a database that has already been running without one of
   them.
3. Add to `server.cfg`, after the five dependencies above (`ox_inventory`
   must be started too, even if you leave every flag that actually uses it —
   Phase 2's `Config.Features.SearchZones`/`ContrabandAlerts`, and Phase 4's
   `K9Inventory`/`K9Medkit`/`MoodSystem`/`DistractionSystem` — at their
   shipped `false` default; it's still declared in `fxmanifest.lua`'s
   `dependencies` block, so the resource won't start without it running):
   ```
   ensure qbx_k9unit
   ```
4. Open `config.lua` and adjust it to your server before going live —
   at minimum:
   - `Config.Departments` — your actual job names and certifier grade
     thresholds (the shipped defaults are `police`, `sheriff`, `bcso`).
   - `Config.Peds` — the dog models you want recognized (defaults to the
     four native canine models).
   - `Config.K9Vehicles` — the vehicle models your K9 can load into.
5. Certify your first handler. See
   [How certification works](#how-certification-works-day-one) below.

## Database

`qbx_k9unit/sql/install.sql` creates a single table, `k9_certifications`,
which is the **sole source of truth** for who currently holds an active K9
certification. It is an append-mostly audit log: granting `INSERT`s a new
row, revoking `UPDATE`s the existing active row to `active = 0` (never
deletes), so the full grant/revoke history per citizen/job is always
reconstructable, including revocations issued while the target was offline.

```sql
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,
  `job`              VARCHAR(50)  NOT NULL,      -- department job name at grant time
  `granted_by`       VARCHAR(50)  NOT NULL,      -- citizenid of the certifying officer
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,  -- citizenid, or the sentinel 'system:job_change' for an automatic revoke
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,
  `active_cert_key`  VARCHAR(105) GENERATED ALWAYS AS (...) VIRTUAL,  -- see install.sql for the full expression
  PRIMARY KEY (`id`),
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),
  KEY `idx_job_active` (`job`, `active`),
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Notes for anyone querying this table directly (e.g. for an admin panel):

- At most **one active row** can exist per `(citizenid, job)` pair — this is
  enforced both in application logic and by the `uq_one_active_cert_per_job`
  unique index on the generated `active_cert_key` column, which closes the
  race window between two near-simultaneous grant requests.
- `revoked_by` can hold a real citizenid **or** the literal string
  `'system:job_change'`, which means the row was auto-revoked because the
  holder left the department (see [Automatic revocation](#automatic-revocation-on-leaving-the-department)),
  not manually pulled by an officer.
- List all currently certified handlers in a department:
  `SELECT citizenid, granted_by, granted_at FROM k9_certifications WHERE job = ? AND active = 1;`
- There is no foreign key to a `players` table on purpose — this resource's
  migration has no install-order dependency on `qbx_core`'s own schema.

A read-only mirror, `metadata.k9certified` (boolean), is also written to the
player's `qbx_core` metadata on every grant/revoke **purely for client-side
HUD/badge display**. It is never read by any server-side authorization
check — the database table above is the only thing that actually grants
access.

`qbx_k9unit/sql/install.sql` also creates three more tables:

- **`k9_search_log`** — an append-only audit trail for every completed
  Phase 2 contraband search (`server/search.lua`), one row per attempt that
  actually reached a real inventory read (`found`/`clean`/`search_failed`
  — early rejections like `on_cooldown`/`too_far` are never logged, since
  they never touched the target). Exists purely for dispute accountability
  ("did this K9 unit actually search my vehicle"); nothing in this resource
  ever reads it back to make an access decision.
- **`k9_partnerships`** — the K9/handler partnership registry
  (`PHASE3_SPEC.md` §12.0 item 7), now backed by real code:
  `server/partnership.lua` reads and writes this table to establish, look
  up, and tear down a mutually-consented "K9 partner" relationship, gated
  by `Config.Features.HandlerPartnership` (still `false` by default) — see
  [Config.Features.HandlerPartnership](#configfeatureshandlerpartnership)
  below. At most one **active** row exists per citizenid, in either the
  `k9_citizenid` or `handler_citizenid` column, enforced by two independent
  unique indexes plus an application-level mutex around every establish
  attempt (see that file's own header for exactly what gap the mutex closes
  that the two independent unique indexes alone cannot). **This registry is
  a foundation only** — nothing in this resource yet reads it to actually
  do anything in combat: `Config.Features.HandlerDownDefense` and
  `PHASE3_SPEC.md`'s Recall mechanic, the two features this registry exists
  to unblock, both still have zero code. Landing this table's consumer
  unblocks building them; it does not deliver either.
- **`k9_progression`** — one row per citizenid (`xp` column, atomically
  upserted via `INSERT ... ON DUPLICATE KEY UPDATE`), backing
  `Config.Features.XPProgression` (`server/progression.lua`). Survives a
  department change, unlike `k9_certifications` — see
  [Config.Features.XPProgression](#configfeaturesxpprogression) below.
  **This table was missing from this migration file until this pass** —
  every `k9_progression` query in `server/progression.lua` is
  pcall-wrapped, so the gap never crashed the resource, it just meant every
  award silently failed to persist: XP still worked correctly in-memory for
  the rest of a session (every tier-based gameplay effect kept applying),
  but a restart or even a reconnect lost all of it. It's present now;
  nothing further is required beyond re-running `sql/install.sql` once
  against an existing database if `XPProgression` was already enabled
  without it (`CREATE TABLE IF NOT EXISTS` makes this safe).

## How certification works, day one

Access to every K9 feature (radial menu, leash, vehicle load) requires,
checked **server-side on every gated action**:

1. The player's current `job.name` is a key in `Config.Departments`, **and**
2. The player holds an **active** row in `k9_certifications` for that exact
   job (or the department's optional `autoAccessGrade` bypass applies — see
   [Config.Departments](#configdepartments)).

Nothing about this is cached client-side as a one-time pass; a modified
client cannot bypass it by lying about its own job, rank, or model.

**Bootstrapping a fresh server** (nobody is certified yet): any officer
whose `job.grade.level` is at or above their department's `certifierGrade`
(or who is the department boss, `job.isboss == true`) can certify
**themselves** via `Config.AllowSelfCertification` (defaults to `true`).
Concretely, day one:

1. A high-rank officer creates/switches to a character using one of the
   models in `Config.Peds` (e.g. `a_c_shepherd`).
2. They get hired into a department listed in `Config.Departments`, at or
   above that department's `certifierGrade` (or as the boss).
3. They run `/k9certify <their own server id>` (or use the in-world
   ox_target "Certify K9 Handler" option on themselves — note the ox_target
   option explicitly excludes targeting yourself, so self-certification is
   command-only).
4. They now pass the access check and can certify every other K9-model
   officer in the department the normal way, either via ox_target or
   `/k9certify [id]`.

If `Config.AllowSelfCertification` is set to `false`, a second certifier-
eligible officer must always be online to grant the first certification.

**Granting a certification** (`/k9certify [server id]` or the ox_target
"Certify K9 Handler" option on a nearby player) requires, all re-verified
server-side:

- The granter's job is a key in `Config.Departments` and their
  `job.grade.level >= certifierGrade` for that department, **or** they are
  the department boss.
- The target's job is a key in `Config.Departments` — **any** configured
  department, not necessarily the same one as the granter (e.g. a police
  chief can certify a sheriff's deputy). This is a deliberate, documented
  design choice, not an oversight.
- The target is online.
- Granter and target are within `Config.CertifyProximityMeters` (default
  `5.0`) of each other, measured from live server-side coordinates — skipped
  only for self-certification (there's no distance to measure to yourself).
- The target's **live** ped model (read server-side, never client-claimed)
  is one of the entries in `Config.Peds`. This check applies to granting
  only.

**Revoking a certification** uses the same certifier-eligibility and
proximity rules as granting, but does **not** check the target's model
(so a handler who has since switched away from a K9 model can still be
revoked). Two paths:

- `/k9decertify [server id]` or the ox_target "Revoke K9 Certification"
  option — target must currently be online.
- `/k9decertifyoffline [citizenid] [job]` — for a target who is genuinely
  disconnected (see [Commands](#commands) below).

## Automatic revocation on leaving the department

Certification is scoped to actual employment. A server-side handler on
`QBCore:Server:OnJobUpdate` automatically revokes a K9's active
certification the moment their `job.name` changes away from the department
that certification was granted for — being fired (or otherwise reassigned)
ends K9 access immediately, without waiting for anyone to manually run
`/k9decertify`.

- The revoke is recorded with `revoked_by = 'system:job_change'` so it's
  distinguishable from a manual pull in the audit trail.
- A **grade change within the same department** (promotion/demotion, where
  `job.name` doesn't change) does **not** trigger a revoke — only actually
  leaving the department does.
- The certification does **not** come back automatically if the player is
  later rehired into the same department. A fresh grant from a qualifying
  certifier is always required.
- If the player is actively in a leash pairing as the K9-role party at the
  moment their cert is revoked (manually, offline, or automatically), that
  leash pairing is force-detached immediately as part of the same handler —
  access loss doesn't leave a stale leash active for the rest of the
  session.

## Config reference

All configuration lives in `config.lua`.

### `Config.Features`

Boolean toggles. The Phase 1 flags below are documented in this table.
Phase 2's flags (`BloodTracking`, `GunpowderSniffing`, `ScentTracking`,
`WaterTrackingDecay`, `SearchZones`, `ContrabandAlerts`, `ThermalVision`,
`NightVision`, `DoorInteraction`) are also read by real, implemented code,
but are documented together with the config tables they gate in
[Phase 2 configuration](#phase-2-configuration-not-enabled-by-default)
below rather than repeated here — see
[Config options not yet wired up](#config-options-not-yet-wired-up) for
the flags that belong to later phases with no code behind them at all yet.

| Flag | Default | What it actually gates |
|---|---|---|
| `LeashMechanics` | `true` | Registers the "Attach Leash" ox_target option and the radial "Attach/Detach Leash" item; server-side, gates whether `requestLeashAttach`/`respondLeashAttach` will ever form a pairing (`CheckLeashEligibility` returns `feature_disabled` if off). |
| `RadialMenu` | `true` | Whether the "K9 Unit" ox_lib radial submenu is registered at all (`lib.addRadialItem` is skipped entirely if `false`). |
| `VehicleEntryExit` | `true` | Registers the "Load K9 Into Vehicle"/"Release K9 From Vehicle" ox_target options and the radial "Enter/Exit Vehicle" item; `EnterNearestK9Vehicle()` also no-ops if this is `false` even if called directly. |
| `BasicBarkSounds` | `true` | Whether the radial "Bark" item is registered, and whether the server's `relayBark` handler will do anything (returns immediately if `false`, so a modified client calling the event directly still gets nothing). |
| `AgilityBasicJump` | `true` | When `true` (default), jump/crouch just work via the ped model's native locomotion — no extra code runs. When set to `false`, a client thread actively **disables** jump (`INPUT_JUMP`) and crouch (`INPUT_DUCK`) for any player currently modeled as a configured K9. |

The "Sit" radial item and the certify/revoke ox_target options have **no**
dedicated `Config.Features` flag — Sit is bundled under the general radial
menu + access check, and certify/revoke are the access-control system
itself (hard requirement, not a togglable feature area), so they're always
registered, the same way `/k9certify`/`/k9decertify`/`/k9decertifyoffline`
are always registered regardless of any flag.

### `Config.Peds`

```lua
Config.Peds = {
    { model = 'a_c_shepherd',   label = 'German Shepherd' },
    { model = 'a_c_rottweiler', label = 'Rottweiler' },
    { model = 'a_c_husky',      label = 'Husky' },
    { model = 'a_c_chop',       label = 'Chop (K9 Unit)' },
}
```

The list of ped models this resource **recognizes** as a K9 character. This
is not a spawn roster — nothing here ever creates a ped; it's compared
against a player's live, already-existing model (`GetEntityModel`) in
exactly two places: the certify-eligibility check (grant only) and the
leash role-assignment check (which of two paired players is the
"constrained" K9 side). Add or remove entries freely, including custom
streamed models — no other `.lua` file needs to change. `label` is
currently unused by any code path (no UI reads it yet) but is kept for
forward compatibility / readability.

### `Config.Departments`

```lua
Config.Departments = {
    ['police'] = {
        label           = 'Los Santos Police Department',
        certifierGrade  = 4,
        autoAccessGrade = nil,
    },
    ['sheriff'] = { label = 'Blaine County Sheriff', certifierGrade = 3, autoAccessGrade = nil },
    ['bcso']    = { label = 'Blaine County Sheriff (legacy job name)', certifierGrade = 3, autoAccessGrade = nil },
}
```

Keyed by **job name** (must exactly match the job names your job system
actually uses — the shipped defaults are placeholders, not guaranteed to
match your server). Each entry:

- `label` (string) — display label only; currently used in the
  auto-revoke notification message, otherwise cosmetic.
- `certifierGrade` (integer) — the minimum `job.grade.level` required to
  grant or revoke K9 certifications for this department. A player whose
  `job.isboss == true` always qualifies as a certifier regardless of this
  number.
- `autoAccessGrade` (integer or `nil`, default `nil`) — **optional**
  per-department bypass. If set to an integer, any player at or above that
  grade level in this department gets K9 feature access even **without**
  an active certification row. Defaults to `nil` (disabled) in the shipped
  config — no rank auto-bypasses certification by default, including a
  department's own boss/chief. This is a one-line opt-in for servers that
  want a rank-based bypass instead of requiring every officer to be
  individually certified.

Cross-department certifying is allowed by default: a certifier from one
configured department can certify a target employed by a **different**
configured department (e.g. a police chief certifying a sheriff's deputy).
There is no same-department restriction built in.

**Adding a custom K9 model:** dropping a new entry into `Config.Peds` (see
the commented-out example in `config.lua`) is enough to make it recognized
for certification and access purposes — no other file needs to change for
that. The one exception is the radial menu's "Sit" action
(`client/movement.lua`'s `K9Sit()`), which maps specific model names to
specific sit animation scenarios via a small hardcoded lookup table, not a
field on `Config.Peds` itself. A newly added model will still work with
Sit, but silently falls back to the German Shepherd sit animation rather
than something breed-appropriate — add a line to that lookup table in code
if you want a matching animation for a new model.

### `Config.AllowSelfCertification`

`boolean`, default `true`. When `true`, a certifier-eligible officer
(grade ≥ `certifierGrade`, or boss) can grant or revoke their **own**
certification via `/k9certify`/`/k9decertify [their own server id]`. This
exists specifically to bootstrap a fresh server — see
[How certification works](#how-certification-works-day-one). Set to
`false` to always require a second officer online to grant/revoke a cert,
even for a boss-rank player certifying themselves.

### `Config.CertifyProximityMeters`

`number` (meters), default `5.0`. Maximum distance between granter and
target, measured from live server-side ped coordinates, allowed when
granting or revoking an **online** target's certification. Applies to both
the ox_target flow and the `/k9certify`/`/k9decertify` commands. Skipped
only for self-certification. Not applied to `/k9decertifyoffline` (there is
no live position to measure for a disconnected player — see
[Commands](#commands)).

### `Config.K9Vehicles`

```lua
Config.K9Vehicles = { 'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2' }
```

List of vehicle **model names** (spawn names, not labels) that expose the
"Load K9 Into Vehicle"/"Release K9 From Vehicle" ox_target options on their
trunk/rear-door area. Any vehicle whose model isn't in this list is invisible
to the K9 vehicle-entry system entirely.

### `Config.VehicleInteractMeters`

`number` (meters), default `3.0`. Maximum distance from a qualifying vehicle
at which the ox_target "Load K9 Into Vehicle" option appears and can be
used, and the max search radius `EnterNearestK9Vehicle()` uses when finding
the nearest eligible vehicle from the radial menu's "Enter/Exit Vehicle"
item.

### `Config.LeashMaxDistance`

`number` (meters), default `8.0`. Read as a "target/working leash range,"
not a literal detach threshold — as its in-code comment now spells out, it
does **three** distinct jobs, none of which is "detach exactly at this
distance":

1. **Initiate range** — the maximum distance between two players allowed
   when starting or accepting a leash attach request (there is no separate
   "attach range" constant — this value is reused for it).
2. **Elastic pull-back start** — once leashed, the K9-role (constrained)
   party's own client starts softly pulling their position back toward the
   handler once they exceed **75%** of this value (`8.0` default → pull-back
   starts at 6m), with the correction strengthening the closer they get to
   150% of this value.
3. **Hard safety-valve auto-detach** — only if the pull-back can't keep up
   (disconnect, teleport, desync) does the leash actually auto-detach, and
   only once distance exceeds **150%** of this value (`8.0` default → ~12m,
   not 8m). This multiplier is a Phase 1 code constant, not itself
   configurable.

If you raise or lower `Config.LeashMaxDistance`, all three behaviors above
move together — there's currently no way to tune, say, the initiate range
independently from the pull-back/detach distances.

### Config options not yet wired up

These exist in `config.lua`. Most have **no functioning code in this
resource using them at all** — unlike Phase 2/3/4/5's implemented
flags/tables (see
[Phase 2 configuration](#phase-2-configuration-not-enabled-by-default),
[Phase 3 configuration](#phase-3-configuration-not-enabled-by-default),
[Phase 4 configuration](#phase-4-configuration-not-enabled-by-default), and
[Phase 5 configuration](#phase-5-configuration-not-enabled-by-default)
below), which are implemented and reviewed even though they default off.
`HandlerDownDefense` below is the one Phase 3 flag left with no code at
all now that its own registry dependency has landed:

- `Config.Features.HandlerDownDefense` (Phase 3) — still **no code at
  all**. The design decision that used to block it (a dedicated "K9
  partnership" registry, `phase2_notes/phase3_handler_partnership_decision.md`)
  has now also been **implemented** — `server/partnership.lua` +
  `client/partnership.lua` are real, registered files (see
  [Config.Features.HandlerPartnership](#configfeatureshandlerpartnership)
  below and [Database](#database) above) — but the registry is a
  foundation only, wiring no combat consequence of its own.
  `HandlerDownDefense`'s own trigger logic, and `PHASE3_SPEC.md`'s Recall
  mechanic (which depends on the same registry), both still have zero
  code. Landing the registry unblocks building either; it does not deliver
  them.
- `Config.Features.ContrabandScreenFX` (Phase 4) — no code at all.
- `Config.Features.ProximityAudioFX`, `PropAttachments`, `FetchMechanic`,
  `CameraFeedPiP` (Phase 5) — no code at all. See the Phase 5 status
  paragraph above for a research pass that reframed, but did not close,
  the blockers for the first two.

`Config.Features.AgilityAdvanced`, `BiteAndHold`, `NonLethalTakedown`,
`PropDragging`, `HandlerPartnership` (Phase 3), `K9Inventory`,
`XPProgression`, `FatigueSystem`, `MoodSystem`, `FearStressSystem`,
`DistractionSystem`, `InjuryLimping`, `K9Medkit`, `HealthStaminaHUD`
(Phase 4), and `AdvancedBarkRadial`, `DeployableKennel` (Phase 5) all
**are** wired up to real, working (if unreviewed-for-numeric-tuning) code
now — see their respective sections below. `BiteAndHold`, `NonLethalTakedown`,
and `PropDragging` are also now reachable from the "K9 Unit" radial menu —
see [Phase 3 configuration](#phase-3-configuration-not-enabled-by-default)
for why they should still not be enabled on a live server despite that.
`Config.XPTiers`/`Config.XP` (Phase 4 — XP thresholds/awards) are also now
read by `server/progression.lua`.

Everything in the bulleted list above is left `false`/present in the
shipped config as a placeholder for future work; there is no harm in
leaving any of it at its defaults.

## Phase 2 configuration (not enabled by default)

Every table in this section lives in `config.lua` and is read by real,
implemented code — `client/tracking.lua`, `client/search.lua`,
`client/vision.lua`, `server/tracking.lua`, `server/search.lua`, plus door
interaction, which was folded into the existing `client/movement.lua` and
`server/main.lua` rather than a new file. This code has been through
security/QA/regression/correctness review passes (`server/search.lua` in
particular was reviewed as the security-critical file of this phase).
**Every gating flag below still ships `false`**, so none of it is active
on an existing install until a server owner deliberately flips a flag —
but that's a default to opt into, not a sign the work itself is
unfinished or unreviewed.

**`Config.Features.ScentTracking`'s server-side trail-source resolution
was implemented this pass** (`server/tracking.lua`'s `findTrackableSource`
callback's `'scent'` branch now resolves a real logged source, fed by a
confirmed `ox_inventory` server-side hook,
`exports.ox_inventory:registerHook('swapItems', ...)` — see `SPEC.md` §9
item 17 and `phase2_notes/scent_source_resolution.md`). It no longer has
the "can never functionally succeed" blocker the earlier draft of this
section described. One residual, disclosed caveat remains: the
ox_inventory hook's exact payload shape/behavior was confirmed by direct
source-reading this session, not by an independent test against a live
`ox_inventory` install, so a one-time dev-time verification (log the hook
payload once and confirm field names match) is recommended before
enabling this in production — see `CHANGELOG.md`'s Known Limitations
section for the exact wording. `BloodTracking`, `GunpowderSniffing`,
`WaterTrackingDecay`, `SearchZones`, `ContrabandAlerts`, `ThermalVision`,
`NightVision`, and `DoorInteraction` have no such caveat at all — each is
implemented, reviewed, and safe to enable end-to-end once you've read its
config section below.

### `Config.Tracking`

```lua
Config.Tracking = {
    Scent     = { maxRange = 40.0, maxAgeSeconds = 900, markerSpacing = 3.0, searchCooldownMs = 5000, relayCooldownMs = 1000 },
    Blood     = { maxRange = 40.0, maxAgeSeconds = 300, markerSpacing = 3.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
    Gunpowder = { maxRange = 40.0, maxAgeSeconds = 120, markerSpacing = 3.0, searchCooldownMs = 5000, relayCooldownMs = 300 },
}
```

Tuning for the three self-search "Track Scent" / "Track Blood" / "Track
Gunpowder" K9 actions (one planned radial item per type, each behind its
own `Config.Features` flag). Ranges are in meters; ages and cooldowns are
in seconds/milliseconds as labeled below.

- **`Scent`** (`Config.Features.ScentTracking`) — trail source is a
  dropped/ground-placed item, logged server-side via a real `ox_inventory`
  `swapItems` hook (`server/tracking.lua`) whenever any player drops an
  item — every dropped item counts as a scent source, with no item-type
  filtering (an open product/gameplay-scope question flagged in
  `phase2_notes/scent_source_resolution.md` §4, not a technical blocker).
  - `maxRange` (meters, default `40.0`) — max distance from the K9's own
    live position to a valid scent source at search time.
  - `maxAgeSeconds` (default `900`) — how long a dropped item stays
    trackable as a scent source. Deliberately longer than `Blood`/
    `Gunpowder`'s 300s/120s since a physical dropped item doesn't decay
    the way a damage/gunfire event does — a judgment call, not
    independently tuned against real gameplay balance.
  - `markerSpacing` (meters, default `3.0`) — spacing between rendered
    trail markers/checkpoints.
  - `searchCooldownMs` (ms, default `5000`) — per-player cooldown between
    "Track Scent" attempts, meant to be enforced server-side, not just
    hidden client-side.
  - `relayCooldownMs` (ms, default `1000`) — per-dropping-player cap on
    how often the `swapItems` hook logs a new scent-source entry. Unlike
    `Blood`/`Gunpowder`'s field of the same name, this is **not** closing
    an anti-forgery gap (the hook is server-to-server; a client cannot
    spoof `payload.source` to claim a drop that didn't happen) — it's
    defense-in-depth against a rapid drop/pickup/drop loop growing the
    server-side scent log unbounded between prune passes.
- **`Blood`** (`Config.Features.BloodTracking`) — trail source is the most
  recently logged damage-event location for a victim.
  - `maxRange`, `markerSpacing`, `searchCooldownMs` — same meaning and
    defaults as `Scent`.
  - `maxAgeSeconds` (default `300`) — damage events older than this are
    pruned from the server-side log and can no longer be returned as a
    valid trail source.
  - `relayCooldownMs` (default `500`) — a **separate, ingest-side**
    cooldown: caps how often a single victim's damage events are logged
    into the trail at all, distinct from `searchCooldownMs` (which
    throttles *querying* the log, not writing to it). Guards against a
    flood of legitimate rapid hits (multiple pellets/DoT ticks) or a
    modified client spamming the relay event. Marked in `config.lua` as a
    placeholder pending a dedicated tuning pass.
- **`Gunpowder`** (`Config.Features.GunpowderSniffing`) — trail source is
  the most recently logged weapon-fire location.
  - `maxRange`, `markerSpacing`, `searchCooldownMs` — same meaning as
    `Scent`.
  - `maxAgeSeconds` (default `120`, deliberately shorter than blood —
    residue is more time-sensitive).
  - `relayCooldownMs` (default `300`) — per-shooter ingest-side cooldown,
    same rationale as `Blood.relayCooldownMs`; also a placeholder pending
    tuning.

### `Config.WaterTrackingDecay`

```lua
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0,
    breaksTrail          = true,
}
```

Gated by `Config.Features.WaterTrackingDecay`. This is **not** a
trackable type of its own — it's a modifier applied to whichever trail
(scent, blood, or gunpowder) is currently being rendered, so it only takes
effect when at least one of those three tracking flags is also enabled and
a trail is actively drawing.

- `sampleIntervalMeters` (meters, default `2.0`) — how often the rendered
  trail path is sampled for water presence while it's being drawn.
- `breaksTrail` (boolean, default `true`) — `true`: crossing water fully
  breaks the trail; a fresh "Track <Type>" command is required to
  re-acquire a trail on the far bank, it does not silently resume. `false`:
  markers within/near the water instead render at reduced opacity and the
  trail continues uninterrupted — a softer alternative.

### `Config.SearchContrabandItems`

```lua
Config.SearchContrabandItems = {
    'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol',
}
```

List of `ox_inventory` item names to be cross-referenced against a
searched vehicle's or person's **actual, live** inventory contents once
`Config.Features.SearchZones` ships. Item weight is intentionally **never**
duplicated into this config — it's meant to be read live from
`ox_inventory`'s own item registry at search time, so this list can never
drift out of sync with a server's real `items.lua` weight values.

> **Placeholder — not production data.** The four item names above are
> illustrative examples only and have not been reviewed against any real
> item economy. Replace this list with the actual contraband item names
> from your own server's `ox_inventory` `items.lua` before ever enabling
> `SearchZones`/`ContrabandAlerts` — shipped as-is, a search will either
> find nothing (if these item names don't exist on your server) or match
> items you never intended to flag as contraband (if they happen to exist
> under these exact names for an unrelated purpose).

### `Config.SearchZones`

```lua
Config.SearchZones = {
    vehicleSearchDistance = 2.0,
    personSearchDistance  = 2.0,
    sniffAnimDurationMs   = 4000,
    searchCooldownMs      = 10000,
    alertBroadcastRadius  = 15.0,
}
```

Gated by `Config.Features.SearchZones` (the search action itself).
`Config.Features.ContrabandAlerts` is a **separate** flag that additionally
gates the alert *broadcast* described under `alertBroadcastRadius` below —
per the design, a search can still privately report its result to the
searching K9 player with `ContrabandAlerts` off; that flag only controls
whether nearby players also get an audible/visual reaction.

- `vehicleSearchDistance` / `personSearchDistance` (meters, default `2.0`
  each) — the ox_target zone radius for the planned "Search Vehicle" /
  "Search Person" options respectively.
- `sniffAnimDurationMs` (ms, default `4000`) — how long the sniff
  interaction plays before a result is revealed; purely cosmetic pacing —
  the real result is meant to be computed server-side regardless of this
  delay, never client-side.
- `searchCooldownMs` (ms, default `10000`) — per-`(K9, target)` pair
  cooldown, meant to prevent repeat searches of the same vehicle/person to
  fish for a different roll or simply to harass.
- `alertBroadcastRadius` (meters, default `15.0`) — **new field added in
  Phase 2's config.** Max distance from the searched target's own live
  coordinates within which a bystander would receive the `ContrabandAlerts`
  sound/reaction broadcast. Deliberately **not** designed as a server-wide
  broadcast the way the bark relay is — unlike a bark, this payload
  identifies a specific vehicle/person just flagged for contraband, so a
  map-wide broadcast would leak that fact to a potential accomplice
  anywhere on the server.

### `Config.ContrabandAlertTiers`

```lua
Config.ContrabandAlertTiers = {
    { minWeight = 0,   alert = 'clean' },
    { minWeight = 1,   alert = 'whine' },
    { minWeight = 250, alert = 'aggressive_bark' },
}
```

Meant to be consulted whenever a search under `Config.Features.SearchZones`
completes; the resulting `alert` would only actually broadcast to nearby
players if `Config.Features.ContrabandAlerts` is also `true` (see
`Config.SearchZones.alertBroadcastRadius` above). **Order matters** — this
list must stay sorted ascending by `minWeight`; the search logic is
designed to walk it and keep the *last* tier whose `minWeight` the total
contraband weight meets or exceeds, so a zero-contraband result should
still resolve to a real, defined tier rather than falling through
unhandled.

The `{ minWeight = 0, alert = 'clean' }` baseline entry is a **new,
mandatory** addition in Phase 2's config — it was not present in the
original draft table, which only defined the two found-contraband tiers.
It exists specifically so a genuinely clean search always has defined
feedback for the requester instead of an unhandled fallback case.

> **Placeholder — not production data.** Like `Config.SearchContrabandItems`
> above, the `minWeight` thresholds (`1`, `250`) are placeholder numbers,
> not the result of an economy/item-weight review. Re-tune them against
> your own server's actual `ox_inventory` item weights before going live —
> as shipped, these numbers have no verified relationship to what a real
> stash on your server would actually weigh.

### `Config.DoorInteraction`

```lua
Config.DoorInteraction = {
    interactDistance      = 1.5,
    nudgeRequiresUnlocked = true,
    scratchCooldownMs     = 3000,
}
```

Gated by `Config.Features.DoorInteraction`. Both **"Scratch to Alert"** and
**"Nudge Door"** are implemented, as two separate ox_target options
registered on the same door-like objects.

**Scratch-to-alert**, as actually implemented (`client/movement.lua` +
`server/main.lua`'s `relayDoorScratch` handler):

- Registers a "Scratch to Alert" ox_target option on nearby door-shaped
  objects, within `interactDistance` of the K9. There's no generic "is
  this a door" native, so the client-side option uses a best-effort
  heuristic (the object's model/archetype name containing the substring
  "door") purely to decide when to *offer* the option — a UX guess only,
  never the security boundary.
- Works on **any door, regardless of lock state**. This is intentional,
  not a gap: the action reveals no inventory or lock-state information at
  all (it's purely a sound cue), so there's nothing lock-state-related to
  check or restrict in the first place.
- Plays a local scratch animation and sound on the acting K9 immediately,
  then round-trips through the server, which independently resolves the
  claimed door entity, confirms it still exists, confirms it's actually an
  object (not a ped/vehicle) near the caller's own live position, and only
  then broadcasts a shared sound cue to every client that currently has
  that door streamed in (`qbx_k9unit:client:playDoorScratch`) — the
  server never trusts the client's own door guess or claimed distance.
- Rate-limited by **two independent, server-side cooldowns that must both
  pass** before a broadcast fires: a per-player cooldown (stops one player
  spamming scratch across many different doors) and a separate per-door
  cooldown (stops multiple — potentially colluding — players from
  hammering the *same* door between them). Both use `scratchCooldownMs` as
  their window; there's no separate config value for the per-door one.

**Nudge Door**, as actually implemented (`client/movement.lua`'s
`NudgeDoor()`, no server file involved at all):

- A **purely cosmetic** push impulse and sound applied to the K9's own ped
  — it never touches the door entity in any way (no freeze/move/rotate,
  and no read of any lock-state native either). The only thing it reads
  from the door entity is its current position, used solely to compute
  which direction the K9's own impulse should face.
- **Zero server involvement.** No `TriggerServerEvent`, no callback,
  nothing server-authoritative is touched — unlike Scratch-to-alert, there
  is no round trip and nothing for the server to validate.
- **This is a hard, non-negotiable safety design, not a missing feature.**
  Nudge-open never calls any door-lock/CDoor native
  (`DoorSystemGetDoorState`, `IsDoorClosed`,
  `GetStateOfClosestDoorOfType`, or any sibling) for any purpose, ever.
  Most real door-lock resources manage their own lock flag entirely
  outside GTA's native door system, so an unregistered door reads as
  "nothing to say" to every one of those natives — treating that as
  license to nudge would make this a real lockpick-equivalent bypass, not
  a theoretical one. Since no confirmed way exists to ask whether an
  arbitrary door object is already passable, the only structurally safe
  design is one that can never open a door at all: a push on the K9's own
  body, never the door.
- Gated purely by `interactDistance` (via ox_target's own `distance`
  option) and `CanShowK9UI()` — no lock/reachability check of any kind,
  because a self-only cosmetic impulse cannot grant any real capability
  regardless of the target door's actual state.

Fields:
- `interactDistance` (meters, default `1.5`) — max distance to a door
  entity at which both the "Scratch to Alert" and "Nudge Door" options are
  offered client-side; also the distance (plus a small server-side latency
  tolerance) the server independently re-checks before ever broadcasting a
  scratch alert.
- `nudgeRequiresUnlocked` (boolean, default `true`) — **enforced only as a
  resource-start assertion, not a runtime branch inside the feature
  itself.** Nudge-open has no real lock-state read anywhere in its
  implementation for this field to meaningfully gate against (see the
  safety design above) — building a real branch off it would require
  exactly the kind of believed-lock-state check that design must never
  perform. Instead, a resource-start `assert` in `client/movement.lua`
  fails the whole resource loudly at startup if this is ever set to
  anything other than `true`, so a future implementer would have to
  deliberately remove that assertion (a reviewed code change) before
  wiring a real, dangerous lock-state branch off this field. It must never
  become an actual lockpick-bypass toggle.
- `scratchCooldownMs` (ms, default `3000`) — the shared cooldown window
  both the per-player and per-door Scratch-to-alert checks above are keyed
  from, the same shape as `BasicBarkSounds`' existing server-side cooldown.
  Nudge-open has no cooldown of its own — it needs none, since it grants
  no capability and touches nothing shared.

### `Config.Vision`

```lua
Config.Vision = {
    Thermal = { toggleKey = 'K' },
    Night   = { toggleKey = 'J' },
}
```

Two independent native-toggle keybinds, no custom shader or asset —
`Thermal` is designed to drive `SetSeethrough`, `Night` to drive
`SetNightvision`. Gated by `Config.Features.ThermalVision` and
`Config.Features.NightVision` respectively (each independently
toggleable). Both are designed to gate on simply *playing a K9-modeled
character* — the same "innate perception, not a granted departmental
privilege" bar the existing camera toggle already uses — not on holding an
active certification.

- `Thermal.toggleKey` (default `'K'`) — the default `RegisterKeyMapping`
  bind for toggling thermal vision on/off. As with the existing camera
  toggle, this is a default only — the actual key is rebindable per-player
  through FiveM's own keybind settings menu, not something a server owner
  locks in solely via this config value.
- `Night.toggleKey` (default `'J'`) — same mechanism, for night vision.

Thermal and night vision are designed to be mutually exclusive at any given
moment (toggling one off should toggle the other off too, if both were
somehow active).

## Phase 3 configuration (not enabled by default)

All four Phase 3 combat/agility mechanics — `AgilityAdvanced`,
`BiteAndHold`, `NonLethalTakedown`, `PropDragging` — and the separate
`HandlerPartnership` registry now have real, registered code behind their
still-`false` flags. `BiteAndHold`, `NonLethalTakedown`, and `PropDragging`
are also reachable from the "K9 Unit" radial menu ("Bite & Hold / Release",
"Non-Lethal Takedown", "Drag / Release"). **Every numeric value in
`Config.Combat` and `Config.Partnership` is an unreviewed placeholder
pending a balance/config-validator pass — do not enable `BiteAndHold`,
`NonLethalTakedown`, or `PropDragging` on a live server before that
review, and before reading the trust-boundary caveat below.** Only
`Config.Features.HandlerPartnership` is currently considered safe to
enable on its own, since it wires no combat consequence of any kind yet.

### `Config.Features.AgilityAdvanced`

`boolean`, default `false`. Gates `client/movement.lua`'s fence/window
vault approximation for a K9-modeled player: a multi-height capsule-sweep
raycast (`Config.Combat.AgilityAdvanced.detectionMethod`, hard-locked to
`'raycast'` — the resource asserts loudly at startup if this is ever set to
anything else, since the alternate `'taggedProp'` shape is documented but
has no implementation) detects a low obstacle ahead of the K9 and vaults it
if it's no taller than `.maxVaultHeight` (meters, default `1.2`), on a
per-K9 cooldown (`.vaultCooldownMs`, default `2000`ms). Does not depend on
`BiteAndHold`/`NonLethalTakedown`/`PropDragging`/`HandlerPartnership` and
has no PvP/trust-boundary caveat — it only ever affects the acting K9's own
ped.

### `Config.Features.BiteAndHold`, `NonLethalTakedown`, `PropDragging`

All three gate real, registered code in `server/combat.lua` +
`client/combat.lua`, all three default `false`, and all three are reachable
from the radial menu once enabled. `Config.Combat.RequireWantedStatus`
(`boolean`, default `true`) applies to all three mechanics' **player**
targets: a K9 may only target a player flagged wanted/suspect (read via
`Config.Combat.WantedStatusCheckOverride(playerId) -> boolean`, a function
hook you should point at your own dispatch resource — `nil` by default,
falling back to a lower-confidence `metadata.wanted`/`metadata.iswanted`
guess). NPC targets are never subject to this check. A separate hook,
`Config.Combat.PropDragging.IsPlayerDownedOverride(targetServerId) ->
boolean|nil`, gates whether a **player** can be targeted for dragging at
all (point it at your own ambulance/laststand resource); both hooks **fail
closed** (treat the target as ineligible) if they error, rather than
falling back to a permissive default.

- **`BiteAndHold`** (`Config.Combat.BiteAndHold`) — `range` (meters,
  default `2.5`), `maxDurationMs` (default `15000` — the hard, non-optional
  "no unbounded trap" timeout for a non-consensual hold), `cooldownMs`
  (default `20000`, per-K9). Suppresses the target's sprint/weapon-fire
  input for the duration (or until the K9 releases early) via
  `DisableControlAction`, applied on the target's own client for a player
  target (a "Category B" relay this resource cannot make the target's
  client actually honor — see the trust-boundary note below) or on the
  requesting K9's own client for an NPC target.
- **`NonLethalTakedown`** (`Config.Combat.NonLethalTakedown`) — `range`
  (default `3.0`), `minTargetSpeed` (m/s, default `4.0`, server-computed
  from a short live position-sample window — never a client-claimed
  "I am sprinting" flag), `speedSampleWindowMs` (default `250`),
  `ragdollDurationMs` (default `4000` — the hard timeout on both the forced
  ragdoll and the damage-suppression bracket), `cooldownMs` (default
  `25000`, per-K9), `targetCooldownMs` (default `30000`, per-target, stops
  several K9s repeat-takedown-ing the same downed target back-to-back),
  `healthFloor` (default `100`, a backstop only — the primary
  non-lethality mechanism is the damage-suppression bracket, not this
  floor). `SetEntityCanBeDamaged` is confirmed client-only, so both the
  player- and NPC-target damage-suppression brackets are applied by
  relaying to the target's/K9's own client rather than server-side.
- **`PropDragging`** (`Config.Combat.PropDragging`) — `range` (default
  `2.5`), `maxDragDistance` (meters, default `30.0` — the real,
  server-enforced "no unbounded trap" backstop, checked unconditionally
  regardless of whether the client-side attach is actually still being
  honored), `maxDragDurationMs` (default `20000`), `dragSpeedMultiplier`
  (default `0.4`, applied to a **player** target's move rate — client-side
  only, see below). The K9's own client re-asserts `AttachEntityToEntity`
  on the target every tick (not once), because a hostile target's own
  client can call `DetachEntity` on itself at any moment to instantly break
  free — **this resource cannot prevent that, only detect it**
  (`Config.Combat.NonComplianceDetection.dragComplianceSlackMeters`,
  default `4.0`m, compares the target's live position against the
  dragging K9's own — a growing gap is logged/notified per
  `Config.Combat.NonComplianceDetection.action` below, never auto-punished).
  Either the holding K9 or, if the target is a player, the target
  themselves can release the drag at any time with zero consent needed
  from the other side.

**Non-compliance detection is logging/staff-notification only, never
enforcement** (`Config.Combat.NonComplianceDetection`, `enabled` default
`true`): it samples an active hold/ragdoll/drag's target position every
`positionSampleWindowMs` (default `500`ms) and flags a likely violation
(fleeing during Bite & Hold, faking a ragdoll, breaking free of a drag)
via `action` (`'log'` or `'notify_staff'` — deliberately never
`'auto_kick'`/`'auto_ban'`, since a false positive from lag/desync must
never itself become punitive without human review) or your own
`OnViolationOverride(playerId, effectType, evidence)` hook. **No
server-authoritative consequence of any kind is ever conditioned on one of
these signals** — a flagged violation never ends the hold early, denies a
cooldown refund, or blocks a future request.

**The trust boundary this resource cannot close, stated plainly:** for a
**player** target, the actual restraining effect (input-disable, forced
ragdoll, move-rate reduction) runs on *that player's own client*, relayed
there by the server. A modified client can choose to ignore the relayed
event outright. This resource's own player-facing text is worded as
best-effort for exactly this reason, and no server-side check ever assumes
the effect actually landed. A dedicated security review found and fixed a
related, more concrete gap: `client/combat.lua`'s event handlers used to be
registered **unconditionally on every client, regardless of any of these
three flags** — meaning a modified client could fire one of these events on
itself directly (e.g. for indefinite self-invincibility) with **zero
server contact, even with `BiteAndHold`/`NonLethalTakedown`/`PropDragging`
all `false`**. Handlers are now gated per-flag, so "flag off" is
genuinely inert again — **this does not mean a locally-forged event is
prevented once the flag is `true`**; that deeper problem remains open and
unsolved. Do not enable any of these three flags on a live server without
understanding this.

### `Config.Features.HandlerPartnership`

`boolean`, default `false`. Gates a mutually-consented "Partner Up" / "Break
Partnership" registry between a K9 and a departmental officer
(`server/partnership.lua`, `client/partnership.lua`, `k9_partnerships`
table — see [Database](#database) above). Unlike the leash pairing, a
partnership is **DB-backed and survives a disconnect or a resource
restart** — it exists specifically to answer "who is this K9's handler
right now" at moments a transient leash pairing cannot.

- **Establishing one**: either party uses the "Partner Up" ox_target option
  on the other (or `RequestPartnerUp(targetServerId)`); the target gets an
  accept/decline prompt. On accept, the server re-validates eligibility a
  second time (closing the same TOCTOU window leash's own consent handshake
  closes) before writing the row. Eligibility mirrors leash's own
  asymmetric shape: the K9-role party needs `HasK9Access`, the officer/
  handler-role party needs only `job.name` in `Config.Departments` — no
  certifier-grade hierarchy, no requirement that the handler hold their own
  K9 certification.
- **A citizenid can hold at most one active partnership at a time**, in
  either role, enforced by two independent DB unique indexes plus an
  in-process mutex around every establish attempt (see
  `server/partnership.lua`'s own header for the exact race the mutex closes
  that the two unique indexes alone cannot).
- **Either party can end it at any time, with zero consent required** —
  same "no unbounded trap" guarantee this resource applies to leash.
  `BreakPartnership()` deliberately never pre-checks a local "am I
  partnered" cache before sending, specifically so a client whose local
  cache is stale (see the gap below) can never be unable to end a real,
  active partnership.
- Losing certification, changing departments, or otherwise leaving the
  department automatically tears down an active partnership server-side
  (`server/certifications.lua` calls `ForceBreakPartnershipForCitizenId`
  from all four of its own certification-change call sites), regardless of
  `Config.Features.HandlerPartnership`'s current value — a partnership
  established while the flag was on must still be torn down by a later
  revoke/department change even if the flag is subsequently flipped off.
- `Config.Partnership.ProximityMeters` (meters, default `5.0`) — max
  distance between the two parties to establish a partnership, both at
  request time and again at accept time.
- `Config.Partnership.RequestTTLMs` (default `30000`ms) / `.RequestCooldownMs`
  (default `1000`ms) — same "a request nobody answers shouldn't linger
  forever" / "stop UI-harassment via repeat prompts" shape as leash's own
  request handshake.
- **This is a foundation only.** Nothing in this resource yet reads a
  partnership to do anything in combat — `Config.Features.HandlerDownDefense`
  and `PHASE3_SPEC.md`'s Recall mechanic, the two features this registry
  exists to unblock, both still have **zero code**.
- **Disclosed, unresolved reconnect gap**: nothing in this registry's
  current contract re-syncs a client's own view of an already-established
  partnership after that client reconnects or this resource restarts —
  `RefreshPartnershipCache` silently repopulates the *server's* own cache on
  `PlayerLoaded`/resource start, but never tells the client anything. That
  means `IsPartnered()`/`GetPartnerServerId()` (`client/partnership.lua`)
  can genuinely return "not partnered"/`nil` for a player who **is** still
  actively partnered per the database, until a fresh consent-handshake
  event reaches that client. In practice this only affects the "Partner Up"
  option's own display check (the server's own eligibility check still
  authoritatively rejects a redundant request either way) and never
  `BreakPartnership()` (which is unconditional by design, see above) — but
  do not build a future feature against these two accessors assuming they
  are always accurate immediately after a reconnect.

## Phase 4 configuration (not enabled by default)

Five Phase 4 flags now have real code behind them: `HealthStaminaHUD`
(below), `K9Inventory`, `K9Medkit`, the five wellbeing flags
(`FatigueSystem`/`MoodSystem`/`FearStressSystem`/`DistractionSystem`/
`InjuryLimping`), and `XPProgression`. Only `ContrabandScreenFX` remains a
placeholder with no code behind it (see
[Config options not yet wired up](#config-options-not-yet-wired-up)). Every
numeric value in this section's config tables is an unreviewed placeholder
pending a config-validator/economy-balance pass — do not flip any of these
flags to `true` on a live server before that review happens.

### `Config.Features.HealthStaminaHUD`

`boolean`, default `false`. Gates `client/hud.lua` — this resource's first
NUI surface (`ui_page 'html/index.html'` in `fxmanifest.lua`). While
`false` (the shipped default), `client/hud.lua` registers **zero** NUI
callbacks and starts **zero** threads — genuinely inert, not merely
invisible.

When enabled, it's a passive, always-visible-while-relevant overlay
showing four vitals for the active K9 character:

- **Health** and **stamina** are read from real client natives
  (`GetEntityHealth`/`GetEntityMaxHealth`, `GetPlayerSprintStaminaRemaining`)
  every poll tick — no network round trip, no dependency on any other
  resource.
- **Hunger** and **thirst** are read from the already-live
  `QBX.PlayerData.metadata` client-side cache (the same source
  `metadata.k9certified` already uses) — **medium confidence**: the exact
  field names (`hunger`/`thirst`) and 0-100 scale have not been
  independently verified against a live `qbx_core` install. Confirm these
  against your own server before enabling this flag in production.
- Visibility is gated on `CanShowK9UI()` — the **same** combinator the
  radial menu uses (K9 model **and** a live server-side access check) —
  not on ped model alone the way thermal/night vision are. This HUD is
  treated as a department-issued monitoring instrument, not the K9's
  innate perception, so it will **not** show for a K9-modeled player who
  isn't currently certified/access-eligible.
- Pushes to the NUI (`hud:updateVitals`) are change-threshold- and
  heartbeat-driven, not a fixed-rate broadcast, to avoid spamming
  `SendNUIMessage`. The overlay never calls `SetNuiFocus` — it has no
  interactive element, by design.

See `phase2_notes/phase4_hud_bridge_design.md` for the full NUI
callback/payload contract if you need to modify `client/hud.lua` or the
`html/` frontend — the two sides must match byte-for-byte on action/
callback names and payload keys.

### `Config.Features.K9Inventory`

`boolean`, default `false`. Gates a per-K9 `ox_inventory` gear stash
(`server/inventory.lua`, `client/inventory.lua`), opened via an "Open K9
Gear" ox_target option on the K9's own ped. The K9 player can always open
their own stash; who else can is controlled by
`Config.K9Inventory.accessScope`, which is **hard-locked to `'department'`
— any player whose job is a key in `Config.Departments` (any grade) may
also open it, the same "shared field equipment" framing this resource
already gives `Config.K9Vehicles`. Setting this to anything other than
`'department'` in `config.lua` crashes the resource at startup**: a
resource-start `assert` in `server/inventory.lua` enforces this
deliberately, because there is no server-owner-facing alternative — see
below for why.

**There used to be a documented `'ownerOnly'` option ("restricted to the
K9's own citizenid"). It never actually worked, and has been removed as a
selectable option, not merely discouraged or deprecated.** A security
review traced `ox_inventory`'s real stash-access path
(`loadInventoryData`'s stash branch and `openInventory`'s own post-resolve
check, both in `modules/inventory/server.lua`/`server.lua`) and found that
access is gated **exclusively** by `stash.groups`, via
`server.hasGroup(player, groups)` — both real check sites are written
`stash.groups and ... and not hasGroup(...)`, so a `nil` `groups` value
(what `'ownerOnly'` produced) short-circuits straight to **allow, for
every caller, unconditionally**. `RegisterStash`'s `owner` argument (the
thing `'ownerOnly'` actually set) is used only for `Inventories` table
keying and DB persistence — it is never compared against the requesting
player's own identity anywhere in `ox_inventory`, and `ox_inventory`'s own
upstream documentation describes the boolean-owner form as explicitly
letting a player "request other player's stashes," so this was never a
bug in `ox_inventory` that could have been relied on getting fixed. Net
effect: once any K9's stash had been registered in a session (trivially
true the first time that K9 opened their own gear), **any connected
player who knew or guessed that K9's citizenid could open the stash
directly from a modified client with full read/write access** — bypassing
proximity, `HasK9Access`, this resource's own cooldown/mutex, and the
feature flag itself, since `ox_inventory` has no concept of that flag.
There is also no `ox_inventory` mechanism available to build a real
per-owner ACL from instead — `groups` is the only access-control primitive
its stash system actually provides — so a genuine "K9's own citizenid
only" mode is not currently implementable against this dependency at all,
not merely unbuilt. See `server/inventory.lua`'s header for the full
source trace. If you need owner-only access on your server, it must come
from a different mechanism outside this resource (e.g. your own
`ox_inventory` fork/patch); do not attempt to reintroduce an `'ownerOnly'`
value here without first confirming `ox_inventory` itself has grown a real
owner-based access check.

Other fields:

- `Config.K9Inventory.slots` (default `5`) / `.maxWeight` (default `8000`,
  the same gram-equivalent unit `ox_inventory` items use) — the stash's
  size.
- `Config.K9Inventory.interactRange` (meters, default `2.0`) — max distance
  for both the ox_target option and the server's own proximity re-check.
- `Config.K9Inventory.allowedItems` — **currently has no effect even if
  set to a list.** Item-whitelist enforcement was not implemented this
  pass; left `nil` (no whitelist) rather than a config value that silently
  does nothing different from `nil`.

### `Config.Features.K9Medkit`

`boolean`, default `false`. Gates a "Treat K9" ox_target world interaction
(`server/medkit.lua`, `client/medkit.lua`) letting an authorized player
consume a real `ox_inventory` item on a nearby K9-model player to restore
health. Authorization is **job-only**, deliberately not gated on the using
player's own K9 certification (treating a K9 is not a K9-handling action):
a job in `Config.Departments`, a job in `Config.K9Medkit.emsJobs` (default
`{ 'ambulance' }`), or a truthy result from the optional
`Config.K9Medkit.IsMedkitUserAuthorizedOverride(usingPlayerServerId)`
function hook (commented out by default).

- `Config.K9Medkit.itemName` (default `'k9_medkit'`) — placeholder item
  name; must exist in your server's real `ox_inventory` items table before
  enabling this flag.
- `Config.K9Medkit.healthRestore` (default `50`) — native health units
  restored, clamped to the K9's real max health, never allowed to overheal.
- `Config.K9Medkit.injuryRestore` (default `40`) — restores the wellbeing
  subsystem's Injury stat (below) once `Config.Features.InjuryLimping` is
  also enabled; a no-op otherwise.
- `Config.K9Medkit.range` (meters, default `2.0`) — server-enforced max
  distance between the using player and the target K9, checked before any
  item consumption or health change.
- `Config.K9Medkit.cooldownMs` (default `60000`) — per-target (K9
  citizenid) cooldown between treatments.

Health restoration is applied by the **target K9's own client**
self-writing an already-clamped, server-computed absolute health value
(never a delta it could reapply) — a cross-owner `SetEntityHealth` write
was not confirmed reliable server-side, so this avoids relying on it.

### K9 wellbeing subsystem

Five independent `boolean` flags, all default `false`:
`Config.Features.FatigueSystem`, `MoodSystem`, `FearStressSystem`,
`DistractionSystem`, `InjuryLimping`. One shared per-citizenid stat store
and one shared server tick (`Config.Wellbeing.tickIntervalMs`, default
`5000`ms) drive all five stats (`server/wellbeing.lua`,
`client/wellbeing.lua`); each stat is only ticked, read, or gated when its
own flag is `true` — a fully-disabled subsystem starts no thread at all.

- **Fatigue** (`Config.Wellbeing.Fatigue`) — decays while the K9 is
  server-detected as sprinting (a rolling position-sample against
  `sprintSpeedThreshold`, default `4.0` m/s), regenerates while idle, and
  drops move speed by `speedPenaltyMultiplier` (default `0.85`) once below
  `speedPenaltyThreshold` (default `30`). `restRegenPerTick`/`restRadius`/
  `restSources` exist in config but are **not wired to any real detection
  this pass** — resting near a configured source has no effect yet.
- **Mood** (`Config.Wellbeing.Mood`) — decays on taking damage
  (`damageDecayAmount`, default `15`), restored by "Pet K9"
  (`petRegenAmount`, default `10`) and "Feed K9" ox_target interactions
  (`feedRegenAmount`, default `20`, consuming `feedItemName` — a
  placeholder item name, `'k9_treat'`), regenerates passively, and drops
  move speed by `performancePenaltyMultiplier` (default `0.9`) below
  `performancePenaltyThreshold` (default `25`). Pet/feed share a
  per-(interactor, target) cooldown, `petCooldownMs` (default `30000`).
- **Fear/Stress** (`Config.Wellbeing.FearStress`) — rises from nearby
  gunfire (reusing Phase 2's gunfire relay, within `gunfireRadius`/
  `gunfireLookbackSeconds`), decays passively, and above
  `hesitationThreshold` (default `70`) imposes a temporary command-refusal
  state (`hesitationDurationMs`, default `8000`ms) that a self-only "Calm
  Down" action (`/k9calmdown`) can reduce early (`calmDownReduceAmount`,
  `calmDownCooldownMs`). The gunfire input now **dedupes by reporting
  source** rather than counting raw relayed events, closing the primary
  way one spamming/forged report could multiply a nearby K9's stress far
  beyond what one real, continuously-firing shooter would cause. This is a
  mitigation, not a full fix: the relay event is payload-less and
  forgeable by design (reused from Phase 2's gunpowder tracking, where a
  forged entry is harmless), and a single determined attacker can still
  keep re-touching it at its own rate limit to hold a nearby K9's
  stress/hesitation elevated indistinguishably from real, continuous
  nearby gunfire — a disclosed residual risk, not something claimed to be
  fully closed. Inert until both `FearStressSystem` and a real consumer of
  `IsHesitating()` are enabled — today that's only the still-`false`,
  no-in-game-entry-point `BiteAndHold`/`NonLethalTakedown` combat feature
  (see [Config options not yet wired up](#config-options-not-yet-wired-up)).
- **Distraction** (`Config.Wellbeing.Distraction`) — a thrown meat-bait
  item (`/k9meatbait`) or an ultrasonic whistle (`/k9whistle`) briefly
  distracts every K9 within the configured radius. **Deliberately usable
  by any player**, not gated on `CanShowK9UI()` — a fleeing suspect using
  one against a pursuing K9 is an intended use case, not an oversight.
  `flashbangImmune` is **aspirational config only, not implemented** — it
  depends on an unconfirmed third-party flashbang/stun resource's event
  shape.
- **Injury** (`Config.Wellbeing.Injury`) — decays on taking damage,
  restored by `K9Medkit` above, and blocks sprint/jump input
  (client-local, not a server-enforced boundary) plus reduces move speed
  below `sprintBlockThreshold`/`jumpBlockThreshold`/`speedPenaltyMultiplier`.

### `Config.Features.XPProgression`

`boolean`, default `false`. Gates server-authoritative XP accumulation per
K9 citizenid (`server/progression.lua`), persisted in the `k9_progression`
table (one row per citizenid, survives a department change — unlike
certification, which is job-scoped). **This table was missing from
`sql/install.sql` until this pass** — every `server/progression.lua` query
against it is pcall-wrapped, so this never crashed the resource, it just
meant no K9's XP ever actually survived a restart or reconnect; the table
is now present (see [Database](#database) above), so a normal
`sql/install.sql` re-run against an existing database is all that's needed
to start persisting correctly. `Config.XP.awards` defines flat XP amounts
per action key:

- `searchContrabandFound` (default `25`) — a successful Phase 2 contraband
  search. **The actual `AwardXP` call for this was previously dead
  code** — `config.lua`'s own comment already described this call site,
  but nothing anywhere had actually wired it up, so no K9 could earn XP
  from a search regardless of this flag. `server/search.lua` now really
  calls it.
- `trackSourceResolved` (default `10`) — awarded only once the K9's own
  client actually **arrives** within `Config.XP.trackArrivalRadius`
  (default `3.0`m) of a resolved scent/blood/gunpowder source within
  `Config.XP.trackArrivalTTLMs` (default `60000`ms) — not just on the
  trail resolving, which would otherwise let a K9 farm XP by repeatedly
  triggering a search without ever finishing it. Wiring this call up also
  introduced, and this same pass also closed, a second farming gap: a K9
  already standing at (or who forges) a source's location could otherwise
  round-trip resolve→report-arrival for free XP with no real travel.
  `server/tracking.lua` now requires the K9's live distance to the source
  at resolve time to be at least 15m before an arrival ticket is even
  created — the cosmetic trail reveal itself is unaffected, only XP
  eligibility is gated on this.
- `biteHoldSuccess` (default `20`) / `takedownSuccess` (default `30`) —
  now wired to real call sites in `server/combat.lua` (`EndHold` and
  `HandleTakedownRequest` respectively), but still dormant in practice:
  `BiteAndHold`/`NonLethalTakedown` ship `false` and have no in-game
  trigger yet (see
  [Config options not yet wired up](#config-options-not-yet-wired-up)).

Crossing a threshold in `Config.XPTiers` immediately applies that tier's
`speedMultiplier`/`scentRange` and pushes a one-time "tier reached"
notification — never on the initial post-login snapshot, only on a real
crossing. `Config.XP.scopePerCitizenidOrJob` currently only supports
`'citizenid'`; a `'job'` alternative is an open, unresolved product
question, not implemented.

## Phase 5 configuration (not enabled by default)

Two Phase 5 flags now have real code behind them, both explicitly R&D-grade
rather than release-hardened: `DeployableKennel` and `AdvancedBarkRadial`.
`ProximityAudioFX`, `PropAttachments`, `FetchMechanic`, and `CameraFeedPiP`
remain uncoded (see
[Config options not yet wired up](#config-options-not-yet-wired-up)). Every
numeric value in `Config.DeployableKennel`/`Config.AdvancedBarkRadial` is an
unreviewed placeholder pending a config-validator pass.

### `Config.Features.DeployableKennel`

`boolean`, default `false`. Lets a certified handler place a world kennel
object near themselves (`/k9deploykennel`, `server/kennel.lua`,
`client/kennel.lua`) and pick it up again via an ox_target option on the
placed object. The **server**, never the client, computes the spawn point
from the handler's own live position and forward vector, and independently
re-validates the placed object's model, entity type, and position (within
a small tolerance) before accepting it as a real kennel — a modified
client cannot report an arbitrary pre-existing networked entity as "the
kennel it just placed."

- `Config.DeployableKennel.propModel` (default `'prop_doghouse_01'`) — a
  **single-source, unconfirmed** prop name, found in an unrelated
  third-party resource's own config default, not independently
  cross-verified. Confirm it actually streams in-engine before relying on
  it.
- `Config.DeployableKennel.fallbackPropModel` (default
  `'prop_tennis_ball'`) — a confirmed-real prop used automatically if the
  primary model fails to load client-side within a timeout. Not
  thematically a kennel; exists purely so a bad `propModel` degrades to
  "an oddly-shaped but real object appears" instead of a silent failure.
- `Config.DeployableKennel.placementForwardOffsetMeters` (default `2.0`),
  `.interactDistanceMeters` (default `2.5`), `.deployCooldownMs` (default
  `5000`), `.pendingPlacementTtlMs` (default `15000`) — placement/cooldown
  tuning.
- **One active kennel per handler is a hardcoded invariant, not a config
  value** — there is deliberately no `maxActivePerHandler` field. Raising
  this limit would need a real code change (the server tracks kennels in a
  single-slot `citizenid -> entry` table, not an array), not a config flip.

Kennels are cleaned up on manual pickup, handler disconnect, and resource
stop — none of these paths can leave a kennel permanently orphaned in the
world.

### `Config.Features.AdvancedBarkRadial`

`boolean`, default `false`. Layered on top of
`Config.Features.BasicBarkSounds` (still required underneath it, same
Phase-5-on-Phase-1 pattern as the tracking flags over `RadialMenu`). When
enabled, the radial menu's single "Bark" action becomes a submenu of three
variants defined in `Config.AdvancedBarkRadial` (Alert/Aggressive/Calm by
default), each sending the existing `qbx_k9unit:server:relayBark` event
with a different `barkType` string — `server/main.lua`'s handler is
unchanged, since it already accepts any opaque, length-capped bark type.
When this flag is off, behavior is byte-for-byte the same as Phase 1's
single generic bark.

#### Bark sounds are placeholders

Neither the Phase 1 bark nor any `AdvancedBarkRadial` variant has real
authored audio behind it. `'bark'`/`'qbx_k9unit_sounds'` (Phase 1) and
`'Bark_Alert'`/`'Bark_Aggressive'`/`'Bark_Calm'` (`AdvancedBarkRadial`) are
all placeholder names with no `.ogg`/`.wav`/`.awc`/`.rel` asset shipped
anywhere in this resource. `PlaySoundFromEntity` with an unrecognized
name/set silently no-ops, so enabling either flag is safe (you'll just
hear nothing) rather than erroring — but you will need to source and wire
in real audio assets yourself before either bark feature is actually
audible. See `SPEC.md` §7 for the full native-only-vs-custom-asset
breakdown.

## Commands

All three are server commands, restricted in-code to players who pass the
certifier-eligibility check (department member at/above `certifierGrade`,
or boss) — not restricted by an ACE permission, so any player who qualifies
by job/grade can use them, not just server admins.

| Command | Usage | Notes |
|---|---|---|
| `/k9certify` | `/k9certify [server id]` | Grants a K9 certification. Requires the granter to be certifier-eligible, the target to be online and in a configured department, both within `Config.CertifyProximityMeters` of each other (skipped for self), and the target's **current live ped model** to be a configured K9 model. Passing your own server id self-certifies (only if `Config.AllowSelfCertification` is `true`). |
| `/k9decertify` | `/k9decertify [server id]` | Revokes a K9 certification from a currently **online** target. Same certifier-eligibility and proximity rules as certify; does not check the target's ped model. If the target is not currently connected, this command refuses and tells the caller to use `/k9decertifyoffline` instead. |
| `/k9decertifyoffline` | `/k9decertifyoffline [citizenid] [job]` | Revokes a K9 certification for a genuinely **disconnected** target, identified by citizenid + job rather than a numeric server id (a disconnected player has neither). Skips the proximity check by necessity (there's no live position to measure), but refuses and points the caller at `/k9decertify` instead if the given citizenid turns out to currently resolve to an online player — this closes what would otherwise be a proximity-check bypass for revoking an online target from anywhere on the map. |

In-world equivalents (no command needed, but self-targeting is excluded —
self-certification is command-only):

- ox_target **"Certify K9 Handler"** / **"Revoke K9 Certification"** —
  appear on any nearby player whose live model matches `Config.Peds`.
- ox_target **"Attach Leash"** — appears on any nearby player if either you
  or they are K9-modeled.
- ox_target **"Load K9 Into Vehicle"** / **"Release K9 From Vehicle"** —
  appear on vehicles whose model is in `Config.K9Vehicles`, within
  `Config.VehicleInteractMeters`.

## Leash mechanic

The leash is a **consensual**, two-player interaction, not something either
side can force on the other:

1. Either the K9 or a nearby officer initiates "Attach Leash" (ox_target on
   the other player, or the radial menu's "Attach/Detach Leash" item, which
   auto-targets the nearest player within `Config.LeashMaxDistance`).
2. The **target** of that request gets an accept/decline prompt
   (`lib.alertDialog`). Nothing activates until they accept — nobody can be
   leashed without agreeing to it first.
3. The server determines which side is the K9 (constrained) party via a
   live server-side model check, never a client-claimed role. If both
   parties happen to be K9-modeled, whoever was asked (the request target)
   becomes the constrained side.
4. The non-K9 ("handler") side must also have a `job.name` in
   `Config.Departments` — an arbitrary player outside a configured
   department cannot hold the other end of a working K9's leash, even with
   consent. The handler side does **not** need their own active K9
   certification.
5. Once attached, movement is **actually restricted**: the K9-role party's
   own client softly pulls their position back as they approach
   `Config.LeashMaxDistance` from the handler (see that config entry
   above), not just a passive notify.
6. **Either party can detach at will, with zero consent required.** This is
   a hard, deliberate design guarantee — nothing in this resource can trap
   a player leashed with no self-service way out. A hard-cap safety-valve
   auto-detach also exists in case of disconnect/teleport/desync.
7. Losing K9 certification while actively leashed (manually, offline, or
   automatically via a job change) force-detaches the pairing immediately.

## Vehicle entry/exit — a deliberate exception

K9 vehicle load/release (`client/vehicle.lua`) is **client-only**, with no
server-side event or re-check at all. This is a deliberate design decision,
not an oversight: the action only freezes/hides/attaches the acting
player's own ped to a nearby vehicle and restores it on exit — it grants no
real capability, and no server-authoritative state currently depends on
whether a player is "in" a K9 vehicle. A modified client gains nothing here
it couldn't already get by calling the same client-side natives on itself
directly. The K9 gear stash (`Config.Features.K9Inventory`, above) has
since landed without needing this — it gates on live proximity/model/
access instead, not vehicle-load state. If a future feature ever does need
to condition something server-authoritative on vehicle-load state, this
will need a real server-side leg added — it does not currently exist.

Both a resource restart mid-ride and the normal "Release From Vehicle"
option restore the player's ped to a visible, unfrozen, collidable state
next to the vehicle — there is no way to get permanently stuck frozen or
invisible from using this feature as intended.

## Server-side security model (for anyone auditing this resource)

Every access point that grants a real capability re-verifies on the
**server**, independent of what the requesting client claims about its own
job, rank, proximity, or ped model:

- `qbx_k9unit:server:hasK9Access` (an `lib.callback`) is the single source
  of truth for "can this player use K9 features right now" — job membership
  + active cert (or `autoAccessGrade`), never ped model.
- Certification grant/revoke re-validates certifier eligibility, target
  eligibility, live proximity, and (grant only) the target's live ped
  model — the client-side ox_target visibility and command availability are
  UX conveniences only.
- Leash formation re-validates eligibility twice (once at the initial
  request, again at accept time, closing the TOCTOU window where either
  side's eligibility changed in between).
- Contraband search (`server/search.lua`) re-validates access twice for the
  same reason: once at request time, and again immediately after its
  (genuinely yielding) `ox_inventory` read returns, closing the window
  where a supervisor revokes the searching officer's certification while
  that read is in flight.
- The automatic revoke-on-job-change path has no client-reachable entry
  point at all.
- K9 Inventory (`server/inventory.lua`) resolves the target's live model,
  connected-player status, and access independently of the client's
  ox_target selection, and re-checks live proximity before ever mutating
  state — but the real access boundary for the stash itself is
  `ox_inventory`'s own **`groups`** check (`server.hasGroup`), not its
  `owner` argument (which is keying/persistence-only and was never a real
  ACL — see [Config.Features.K9Inventory](#configfeaturesk9inventory)
  below) and not this resource's own re-check, which is defense-in-depth
  on top of the real `groups` gate.
- K9 Medkit (`server/medkit.lua`) and the wellbeing subsystem's Pet/Feed/
  Distraction interactions (`server/wellbeing.lua`) all independently
  re-derive the target's live model and live proximity, and consume a real,
  server-checked `ox_inventory` item before mutating any state — a
  client-reported "I used it" is never sufficient.
- Deployable kennel placement (`server/kennel.lua`) computes the spawn
  point from the requester's own live server-side position — the client
  never supplies a coordinate — and independently re-validates the placed
  object's model, entity type, and position before accepting it as real.
- The K9/handler partnership registry (`server/partnership.lua`)
  re-validates eligibility twice, same TOCTOU discipline as leash and
  contraband search, and enforces "at most one active partnership per
  citizenid" with a DB-level unique-index backstop plus an in-process
  mutex around every establish attempt — see
  [Config.Features.HandlerPartnership](#configfeatureshandlerpartnership)
  above for exactly what gap the mutex closes that the unique indexes alone
  cannot.
- `BiteAndHold`/`NonLethalTakedown`/`PropDragging` (`server/combat.lua`)
  independently re-validate `HasK9Access`, live proximity,
  `Config.Combat.RequireWantedStatus` (for a player target), and their own
  cooldowns before granting an effect — but **this is the one area of this
  resource where the server cannot fully enforce its own decision**: for a
  player target, the actual restraining effect runs on that player's own
  client, relayed there by the server, and a modified client can simply
  ignore it. This resource's own player-facing text is worded as
  best-effort for exactly this reason. `client/combat.lua`'s event handlers
  are now gated per-flag (closing a real gap where a modified client used
  to be able to trigger an effect like indefinite self-invincibility with
  zero server contact even with every flag `false`), but that gating does
  **not** make an individual handler verify a specific invocation actually
  came from the server once its flag is `true` — that remains a separate,
  open item. Do not enable any of these three flags on a live server before
  reading [Config.Features.BiteAndHold, NonLethalTakedown, PropDragging](#configfeaturesbiteandhold-nonlethaltakedown-propdragging)
  above in full.
- The one deliberate exception to "the server always re-verifies" in the
  sense of never round-tripping to the server at all (as opposed to the
  combat trust-boundary caveat above, which does round-trip but can't force
  compliance) is vehicle entry/exit — see above.

## Where things live

- `fxmanifest.lua`, `config.lua` — manifest and config, at the resource root.
- `sql/install.sql` — the one-time DB migration (`k9_certifications` table).
- `server/certifications.lua` — the certification/permission system: grant,
  revoke (online and offline), the in-memory access cache, automatic
  revocation on job change, and the `/k9certify`, `/k9decertify`,
  `/k9decertifyoffline` commands.
- `server/cooldowns.lua` — shared `NewCooldown`/`NewNestedCooldown`/
  `NewMutex` constructors backing every cooldown/mutex table across this
  resource's other server files (a pure structural extraction, no behavior
  change). Loaded first in `fxmanifest.lua`'s `server_scripts`, since every
  other server file calls these constructors at its own file-load time.
- `server/entities.lua` — the shared `ResolveNetworkEntity(netId,
  expectedEntityType?)` defensive netId-to-entity resolver, extracted out
  of two independent hand-written copies in `server/main.lua` and
  `server/search.lua`. Loaded alongside `server/cooldowns.lua`, before its
  consumers.
- `server/main.lua` — the bark relay, the full leash consent/state
  handshake and in-memory leash-pair registry, a resource-start cache
  backfill for already-connected players, and (Phase 2) the
  `relayDoorScratch` handler backing "Scratch to Alert" (resolves and
  existence/type/proximity-checks the claimed door entity, enforces the
  per-player and per-door cooldowns, then broadcasts the sound cue).
- `client/main.lua` — the local K9-model self-check (display only), the
  `hasK9Access` callback wrapper (`HasK9Access()`, short-TTL cached), the
  `CanShowK9UI()` combinator every other client file gates on, and the bark
  playback receiver.
- `client/movement.lua` — camera toggle (`L` key by default,
  rebindable), the "Sit" self-emote, the full client side of the leash
  subsystem (consent prompt, elastic pull-back thread, detach), the
  "Attach Leash"/"Certify K9 Handler"/"Revoke K9 Certification" ox_target
  options, the jump/crouch suppression thread used when
  `Config.Features.AgilityBasicJump` is `false`, and (Phase 2) both
  door-interaction ox_target options — "Scratch to Alert" (plus its
  `playDoorScratch` broadcast receiver) and "Nudge Door" (fully
  client-local, no server file involved) — plus the resource-start
  `assert` that refuses to start the resource if
  `Config.DoorInteraction.nudgeRequiresUnlocked` is ever set to `false`.
  See [Config.DoorInteraction](#configdoorinteraction) above.
- `client/radial.lua` — the ox_lib "K9 Unit" radial menu wiring (Sit, Bark,
  Attach/Detach Leash, Enter/Exit Vehicle).
- `client/vehicle.lua` — K9 vehicle load/release and its ox_target options.
- `client/hud.lua`, `html/index.html`/`style.css`/`app.js` — **Phase 4,
  disabled by default.** The passive vitality HUD and its NUI frontend —
  see [Config.Features.HealthStaminaHUD](#configfeatureshealthstaminahud)
  above.
- `client/tracking.lua`, `client/search.lua`, `client/vision.lua`,
  `server/tracking.lua`, `server/search.lua` — **Phase 2, implemented and
  reviewed, disabled by default.** Scent/blood/gunpowder tracking, search
  zones/contraband alerts, and thermal/night vision respectively — real,
  reviewed logic, not stubs (`server/search.lua` was reviewed as this
  phase's security-critical file). Every `Config.Features` flag these
  files read still ships `false`. `Config.Features.ScentTracking`'s
  server-side trail-source resolution is now implemented (this pass), with
  one residual, disclosed caveat (the ox_inventory hook it relies on was
  confirmed by source-reading, not by an independent live-install test) —
  see [Phase 2 configuration](#phase-2-configuration-not-enabled-by-default)
  above and `CHANGELOG.md`'s Known Limitations section for the exact
  remaining detail before enabling it in production.
- `server/inventory.lua`, `client/inventory.lua` — **Phase 4, disabled by
  default.** The K9 gear stash — see
  [Config.Features.K9Inventory](#configfeaturesk9inventory) above.
- `server/medkit.lua`, `client/medkit.lua` — **Phase 4, disabled by
  default.** The K9 medkit — see
  [Config.Features.K9Medkit](#configfeaturesk9medkit) above.
- `server/wellbeing.lua`, `client/wellbeing.lua` — **Phase 4, disabled by
  default.** The unified Fatigue/Mood/FearStress/Distraction/Injury
  wellbeing subsystem — see
  [K9 wellbeing subsystem](#k9-wellbeing-subsystem) above.
- `server/progression.lua`, `client/progression.lua` — **Phase 4, disabled
  by default.** XP accumulation, persistence (`k9_progression` table), and
  tier application — see
  [Config.Features.XPProgression](#configfeaturesxpprogression) above.
- `server/kennel.lua`, `client/kennel.lua` — **Phase 5 R&D scaffold,
  disabled by default.** The deployable kennel — see
  [Config.Features.DeployableKennel](#configfeaturesdeployablekennel) above.
  `client/radial.lua`'s Bark item also gained an `AdvancedBarkRadial`
  submenu branch (same file, no new file) — see
  [Config.Features.AdvancedBarkRadial](#configfeaturesadvancedbarkradial)
  above.
- `server/combat.lua`, `client/combat.lua` — **Phase 3, both registered in
  `fxmanifest.lua`, all three flags still `false`, reachable via the "K9
  Unit" radial menu.** `BiteAndHold`, `NonLethalTakedown`, and (newly)
  `PropDragging` are all fully implemented under the resolved
  client-relay-architecture design decision (§12.0 item 8) — a real change
  from an earlier state where `server/combat.lua` existed with no client
  counterpart and was deliberately excluded from the manifest, and a later
  state where both were implemented but had no in-game trigger at all.
  Completing the client half found and fixed a real safety bug:
  `SetEntityCanBeDamaged` is client-only, so `NonLethalTakedown`'s
  NPC-target branch calling it server-side was a silent no-op that could
  let a "non-lethal" takedown actually kill an NPC. Landing `PropDragging`
  found two more real gaps, both now fixed: `NetworkRequestControlOfEntity`
  was never requested before driving natives against an NPC target this
  K9's own client doesn't already control (which could have made the
  takedown safety fix above silently no-op again on a populated server),
  and `client/combat.lua` had no `onResourceStop` handler despite setting
  several persistent native flags. A security review separately found
  every event handler in `client/combat.lua` had been registered
  **unconditionally**, so a modified client could trigger effects like
  indefinite self-invincibility with zero server contact even with all
  three flags `false` — now gated per-mechanic, but **this does not close
  the deeper client-relay trust boundary** once a mechanic is enabled (see
  [Config.Features.BiteAndHold, NonLethalTakedown, PropDragging](#configfeaturesbiteandhold-nonlethaltakedown-propdragging)
  above). Do not treat any of the three as a usable-on-a-live-server
  feature yet; see `CHANGELOG.md`'s Known Limitations for the full detail.
- `server/partnership.lua`, `client/partnership.lua` — **Phase 3, both
  registered in `fxmanifest.lua`, flag still `false`.** The K9/handler
  partnership registry — a foundation only, wiring no combat consequence
  of its own; `HandlerDownDefense` and `PHASE3_SPEC.md`'s Recall mechanic
  still have zero code — see
  [Config.Features.HandlerPartnership](#configfeatureshandlerpartnership)
  above.

There are no `exports` declared by this resource (no `server_exports` /
`client_exports` in `fxmanifest.lua`) — integration by other resources is
currently limited to reading the `metadata.k9certified` display flag on a
player, or listening for the net events documented above if you need
tighter coupling (these are internal contracts, not a stable public API,
and may change between phases).

See `SPEC.md` for the full product spec, the phased build plan beyond
Phase 1, and open design questions still flagged for future sign-off.
