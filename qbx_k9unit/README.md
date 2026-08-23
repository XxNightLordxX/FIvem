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
One flag is a hard exception rather than just an off-by-default: **do not
enable `Config.Features.ScentTracking`** — its server-side trail-source
resolution isn't implemented, so it can never functionally succeed even
once enabled (see `SPEC.md` §9 item 17). Every other Phase 2 flag is
implemented, reviewed, and safe to enable once you've read its config
section below. Door interaction itself only ships **scratch-to-alert**;
its "nudge-open" sub-feature was deliberately not built this pass — see
[Config.DoorInteraction](#configdoorinteraction) below. Later phases
beyond Phase 2 (bite-and-hold, inventory/XP, audio/prop polish; see
`SPEC.md` §8) have no code at all yet, and several `Config.Features` flags
and config blocks that belong to those phases exist in `config.lua` purely
as placeholders (see
[Config options not yet wired up](#config-options-not-yet-wired-up)).

## Dependencies

Install and **start these before** `qbx_k9unit` (declared in
`fxmanifest.lua`'s `dependencies` block):

| Resource | Source | Notes |
|---|---|---|
| [`qbx_core`](https://github.com/Qbox-project/qbx_core) | Qbox-project | Player data, jobs, `GetPlayer`/`GetPlayerByCitizenId` exports, `QBCore:Server:OnJobUpdate` / `QBCore:Server:PlayerLoaded` events |
| [`ox_lib`](https://github.com/overextended/ox_lib) | overextended | `lib.callback`, `lib.notify`, `lib.alertDialog`, `lib.addRadialItem` |
| [`ox_target`](https://github.com/overextended/ox_target) | overextended | In-world interaction options (leash, certify/revoke, vehicle load) |
| [`oxmysql`](https://github.com/overextended/oxmysql) | overextended | Database access for the certification table |
| [`ox_inventory`](https://github.com/overextended/ox_inventory) | overextended | **Phase 2** (`server/search.lua`) — reads a searched vehicle's/person's real inventory contents and live item weights for the contraband-search feature. Implemented and reviewed; exists to support `Config.Features.SearchZones`/`ContrabandAlerts`, which ship `false` by default. Still required to be **started** (declared in `fxmanifest.lua`'s `dependencies`) even while those flags are `false`. |

Qbox/QBCore data model only — there is no ESX support.

## Installation

1. Drop `qbx_k9unit` into your server's `resources` folder.
2. **Run the SQL migration before first start.** Import
   `qbx_k9unit/sql/install.sql` against your database with your usual DB
   client (phpMyAdmin, HeidiSQL, the `mysql` CLI, etc.) — this resource does
   not auto-execute it. It creates one table, `k9_certifications`, and is
   idempotent (`CREATE TABLE IF NOT EXISTS`) if you accidentally run it
   twice.
3. Add to `server.cfg`, after the five dependencies above (`ox_inventory`
   must be started too, even though nothing in this resource uses it unless
   you enable Phase 2's `Config.Features.SearchZones`/`ContrabandAlerts` —
   it's still declared in `fxmanifest.lua`'s `dependencies` block, so the
   resource won't start without it running):
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
    { model = 'a_c_huskie',     label = 'Husky' },
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

These exist in `config.lua` but **no code in this resource reads them at
all** — unlike Phase 2's flags/tables (see
[Phase 2 configuration](#phase-2-configuration-not-enabled-by-default)
below), which are implemented and reviewed even though they default off,
everything below belongs to a phase with no code behind it yet:

- `Config.Features.BiteAndHold`, `NonLethalTakedown`, `HandlerDownDefense`,
  `PropDragging`, `AgilityAdvanced` (Phase 3)
- `Config.Features.K9Inventory`, `XPProgression`, `HealthStaminaHUD`,
  `FatigueSystem`, `MoodSystem`, `FearStressSystem`, `DistractionSystem`,
  `InjuryLimping`, `K9Medkit`, `ContrabandScreenFX` (Phase 4)
- `Config.Features.AdvancedBarkRadial`, `ProximityAudioFX`,
  `PropAttachments`, `FetchMechanic`, `DeployableKennel`, `CameraFeedPiP`
  (Phase 5)
- `Config.XPTiers` (Phase 4 — XP thresholds/speed/scent-range tiers)

These blocks are carried over verbatim from the original design spec with
no code behind them at all yet. All of the above are left
`false`/present in the shipped config as a placeholder for future work;
there is no harm in leaving any of them at their defaults.

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

The one real exception: **`Config.Features.ScentTracking` must NOT be
enabled.** Unlike the other flags below, this one has an actual,
documented functional blocker, not just a conservative default —
`server/tracking.lua`'s `findTrackableSource` callback's `'scent'` branch
always returns "nothing found" because its server-side trail-source
resolution was never implemented (no confirmed `ox_inventory`
drop-location hook exists to resolve where a scent trail should
originate — see `SPEC.md` §9 item 17). Turning this flag on ships a
feature that can never functionally succeed end-to-end, not merely an
unreviewed one. `BloodTracking`, `GunpowderSniffing`,
`WaterTrackingDecay`, `SearchZones`, `ContrabandAlerts`, `ThermalVision`,
`NightVision`, and `DoorInteraction` do not have this problem — each is
implemented and reviewed end-to-end and is safe to enable once you've read
its config section below.

### `Config.Tracking`

```lua
Config.Tracking = {
    Scent     = { maxRange = 40.0, markerSpacing = 3.0, searchCooldownMs = 5000 },
    Blood     = { maxRange = 40.0, maxAgeSeconds = 300, markerSpacing = 3.0, searchCooldownMs = 5000, relayCooldownMs = 500 },
    Gunpowder = { maxRange = 40.0, maxAgeSeconds = 120, markerSpacing = 3.0, searchCooldownMs = 5000, relayCooldownMs = 300 },
}
```

Tuning for the three self-search "Track Scent" / "Track Blood" / "Track
Gunpowder" K9 actions (one planned radial item per type, each behind its
own `Config.Features` flag). Ranges are in meters; ages and cooldowns are
in seconds/milliseconds as labeled below.

- **`Scent`** (`Config.Features.ScentTracking`) — trail source is a
  dropped/ground-placed item.
  - `maxRange` (meters, default `40.0`) — max distance from the K9's own
    live position to a valid scent source at search time.
  - `markerSpacing` (meters, default `3.0`) — spacing between rendered
    trail markers/checkpoints.
  - `searchCooldownMs` (ms, default `5000`) — per-player cooldown between
    "Track Scent" attempts, meant to be enforced server-side, not just
    hidden client-side.
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

Gated by `Config.Features.DoorInteraction`. **Only "Scratch to Alert" is
implemented.** "Nudge-open" — a cosmetic push-open interaction — was
deliberately **not** built this pass; treat `DoorInteraction` as shipping
scratch-to-alert alone, not "door interaction" in general. See the
"NUDGE-OPEN NOT IMPLEMENTED" comment block in `client/movement.lua` for
the full reasoning (it's scoped in `SPEC.md` §11.1 as a stretch item, not
a blocker for shipping scratch-to-alert).

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

Fields:
- `interactDistance` (meters, default `1.5`) — max distance to a door
  entity at which the "Scratch to Alert" option is offered client-side,
  and the distance (plus a small server-side latency tolerance) the
  server independently re-checks before ever broadcasting.
- `nudgeRequiresUnlocked` (boolean, default `true`) — **currently inert**:
  nothing reads this value day-to-day, because nudge-open (the only
  feature it would ever gate) isn't implemented yet. It's documented, in
  `config.lua`'s own inline comment and this README, as a hard safety
  requirement that must stay `true` — a resource-start `assert` in
  `server/main.lua` actively enforces this today (the resource refuses to
  start at all if this is ever set to `false`), specifically so it can't
  be silently mis-set before nudge-open exists to read it. It must never
  become a lockpick-bypass toggle once nudge-open is eventually built.
- `scratchCooldownMs` (ms, default `3000`) — the shared cooldown window
  both the per-player and per-door checks above are keyed from, the same
  shape as `BasicBarkSounds`' existing server-side cooldown.

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
directly. If a future feature (e.g. a K9 stash) ever needs to condition
something server-authoritative on vehicle-load state, this will need a real
server-side leg added — it does not currently exist.

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
- The automatic revoke-on-job-change path has no client-reachable entry
  point at all.
- The one deliberate exception is vehicle entry/exit — see above.

## Where things live

- `fxmanifest.lua`, `config.lua` — manifest and config, at the resource root.
- `sql/install.sql` — the one-time DB migration (`k9_certifications` table).
- `server/certifications.lua` — the certification/permission system: grant,
  revoke (online and offline), the in-memory access cache, automatic
  revocation on job change, and the `/k9certify`, `/k9decertify`,
  `/k9decertifyoffline` commands.
- `server/main.lua` — the bark relay, the full leash consent/state
  handshake and in-memory leash-pair registry, a resource-start cache
  backfill for already-connected players, and (Phase 2) the
  `relayDoorScratch` handler backing "Scratch to Alert" (resolves and
  existence/type/proximity-checks the claimed door entity, enforces the
  per-player and per-door cooldowns, then broadcasts the sound cue) plus a
  resource-start `assert` that refuses to start the resource if
  `Config.DoorInteraction.nudgeRequiresUnlocked` is ever set to `false`.
- `client/main.lua` — the local K9-model self-check (display only), the
  `hasK9Access` callback wrapper (`HasK9Access()`, short-TTL cached), the
  `CanShowK9UI()` combinator every other client file gates on, and the bark
  playback receiver.
- `client/movement.lua` — camera toggle (`L` key by default,
  rebindable), the "Sit" self-emote, the full client side of the leash
  subsystem (consent prompt, elastic pull-back thread, detach), the
  "Attach Leash"/"Certify K9 Handler"/"Revoke K9 Certification" ox_target
  options, the jump/crouch suppression thread used when
  `Config.Features.AgilityBasicJump` is `false`, and (Phase 2) the
  "Scratch to Alert" door-interaction ox_target option plus its
  `playDoorScratch` broadcast receiver — see
  [Config.DoorInteraction](#configdoorinteraction) above; nudge-open is
  not implemented here.
- `client/radial.lua` — the ox_lib "K9 Unit" radial menu wiring (Sit, Bark,
  Attach/Detach Leash, Enter/Exit Vehicle).
- `client/vehicle.lua` — K9 vehicle load/release and its ox_target options.
- `client/tracking.lua`, `client/search.lua`, `client/vision.lua`,
  `server/tracking.lua`, `server/search.lua` — **Phase 2, implemented and
  reviewed, disabled by default.** Scent/blood/gunpowder tracking, search
  zones/contraband alerts, and thermal/night vision respectively — real,
  reviewed logic, not stubs (`server/search.lua` was reviewed as this
  phase's security-critical file). Every `Config.Features` flag these
  files read still ships `false`, and `Config.Features.ScentTracking`
  specifically must not be enabled at all (unresolved trail-source
  blocker). See
  [Phase 2 configuration](#phase-2-configuration-not-enabled-by-default)
  above for the full config and the `ScentTracking` blocker's details.

There are no `exports` declared by this resource (no `server_exports` /
`client_exports` in `fxmanifest.lua`) — integration by other resources is
currently limited to reading the `metadata.k9certified` display flag on a
player, or listening for the net events documented above if you need
tighter coupling (these are internal contracts, not a stable public API,
and may change between phases).

See `SPEC.md` for the full product spec, the phased build plan beyond
Phase 1, and open design questions still flagged for future sign-off.
