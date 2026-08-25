# qbx_k9unit

Player-controlled K9 unit for Qbox police/security departments.

The K9 is **a player's own persistent character** — someone creates their
character as a dog ped (German Shepherd, Rottweiler, Husky, Chop, or any
other model added to `Config.Peds`) through your server's normal
character-creation flow, gets hired into a K9-eligible department through
your normal job-hiring flow, and is then **certified** by a qualifying
officer using this resource. This resource does **not** spawn, despawn, or
possess a ped on anyone's behalf — certification is purely an access-control
layer on top of a player who is already playing as a dog.

> **CORRECTION, docs-consolidation pass, 2026-08-25: every `Config.Features`
> flag is now `true`.** Verified by reading `config.lua` directly, not
> assumed. Every "ships `false`"/"Default: `false`" statement below this
> point describes the value this resource *shipped with*, not its current
> value — none of that surrounding prose was rewritten, because the
> caveats attached to each flag are still exactly the things worth knowing
> before you *trust* that flag in production, whether you are the one who
> flipped it or not. Read them as "here is what to understand about this,"
> not as "here is what to consider before enabling it." Two things this
> change makes urgent, not hypothetical:
>
> 1. **`Config.Features.BoneSweepDevTool` is `true`.** Its own code comment
>    says, verbatim, never to enable this on a production server — it
>    spawns and attaches real objects in the world on command. If this
>    server has real players on it, turn this back to `false` and restart
>    the resource (a flag flip alone does not unregister the command —
>    see `OPERATOR_RUNBOOK.md` §4) before reading anything else here.
> 2. **The combat features (`BiteAndHold`, `NonLethalTakedown`,
>    `PropDragging`) are live**, and the two open questions that were meant
>    to gate a decision to enable them (D3, D13 — see `DEVELOPER_REFERENCE.md` §17)
>    are still unanswered. Turning the flag on did not answer them.
>
> For the full current picture in plain language, see `DEVELOPER_REFERENCE.md` §17.
> This file's own content below was not rewritten for the flag change
> beyond this notice and a few load-bearing corrections, per this
> resource's own "layer a correction, don't rewrite history" documentation
> convention — check `config.lua` directly for anything this notice
> doesn't cover.

> **Read this before you deploy.** This is a large, actively-developed
> resource with several `Config.Features` flags whose backing code landed
> only very recently. **Every `.lua` file on disk is now registered in
> `fxmanifest.lua`** — re-verified directly against the current manifest
> while writing this pass, not assumed from an earlier note. That includes
> the last two files this document used to flag as having no manifest
> caller at all (`client/audio.lua`'s NUI sound bridge now has a real
> caller — see [Bark sounds](#bark-sounds-now-ship-with-real-audio)
> below) and the full Phase 5 R&D batch
> (`client/propattachment.lua`/`server/propattachment.lua`,
> `client/fetch.lua`/`server/fetch.lua`, `client/proximityaudio.lua`,
> `client/bonetool.lua`/`server/bonetool.lua`). See
> [Known issues — historical, now resolved](#known-issues--historical-now-resolved)
> for what used to be wrong here. A flag still shipping `false` is not the
> same thing as a file not running — check each flag's own row in the
> [config reference](#configfeatures--full-reference) below for what's
> actually reachable today, since this resource is being edited by multiple
> agents in parallel and this snapshot can go stale quickly.

## Status at a glance

**Table below describes the shipped-default state of each phase, as
originally written. As of 2026-08-25, every flag named below (and every
other flag in this resource) is `true` — see the correction notice at the
top of this file and `DEVELOPER_REFERENCE.md` §17 for what's actually live today.**

| Phase | Area | State (as originally shipped) |
|---|---|---|
| 1 | Certification, leash, radial menu, vehicle load, bark | Feature-complete, enabled by default |
| 2 | Tracking, search zones/contraband, vision, door interaction | Implemented, reviewed, shipped **disabled** — now enabled |
| 3 | Bite & Hold, Non-Lethal Takedown, Prop Dragging, Advanced Agility, Handler Partnership, Handler-Down Defense | Implemented, shipped **disabled** — now enabled; combat mechanics have an open client-trust caveat, and two safety questions (D3/D13 in `DEVELOPER_REFERENCE.md` §17) are still unresolved despite being live |
| 4 | K9 Inventory, K9 Medkit, wellbeing (Fatigue/Mood/FearStress/Distraction/Injury), XP progression, vitality HUD | Implemented, shipped **disabled** — now enabled. `ContrabandScreenFX` is wired end-to-end (client file loaded, server-side trigger fires) |
| 5 | Deployable kennel, advanced bark radial, prop attachments, fetch, proximity audio | Implemented (R&D-grade), shipped **disabled** — now enabled. `DeployableKennel`, `AdvancedBarkRadial`, `ProximityAudioFX`, `PropAttachments`, and `FetchMechanic` all have real client/server code and are **registered in `fxmanifest.lua`**, reachable via the radial menu (Deploy Kennel, Toggle K9 Vest, Fetch). `PropAttachments`/`FetchMechanic`'s attach point is still the root-bone placeholder pending the dev-only bone-index sweep (`client/bonetool.lua`/`server/bonetool.lua`, also registered, ACE-gated, and **also now `true` — see the top-of-file correction notice, this one must not stay on**) — see Known issues. `CameraFeedPiP` is confirmed impossible with current natives regardless of its flag value (see below) |

**As originally shipped, only five `Config.Features` flags shipped `true`:**
`LeashMechanics`, `RadialMenu`, `VehicleEntryExit`, `BasicBarkSounds`,
`AgilityBasicJump`. **That is no longer the current state** — every flag in
this resource is `true` as of 2026-08-25 (verified directly against
`config.lua`; re-check it yourself if time has passed).

## Dependencies

Install and **start these before** `qbx_k9unit` (declared in
`fxmanifest.lua`'s `dependencies` block):

| Resource | Source | Used for |
|---|---|---|
| [`qbx_core`](https://github.com/Qbox-project/qbx_core) | Qbox-project | Player data, jobs, `GetPlayer`/`GetPlayerByCitizenId` exports, `QBCore:Server:OnJobUpdate`/`PlayerLoaded` events |
| [`ox_lib`](https://github.com/overextended/ox_lib) | overextended | `lib.callback`, `lib.notify`, `lib.alertDialog`, `lib.addRadialItem` |
| [`ox_target`](https://github.com/overextended/ox_target) | overextended | In-world interaction options (leash, certify/revoke, vehicle load, etc.) |
| [`oxmysql`](https://github.com/overextended/oxmysql) | overextended | Database access for certification/search-log/partnership/progression tables |
| [`ox_inventory`](https://github.com/overextended/ox_inventory) | overextended | Item weights/contents for contraband search (Phase 2); the K9 gear stash, medkit consumption, and feed/meat-bait/whistle items (Phase 4) |

Qbox/QBCore data model only — there is no ESX support. `ox_inventory` must
be **started** even if every flag that uses it stays at its shipped `false`
default — it's a hard `fxmanifest.lua` dependency regardless.

## Installation

1. Drop `qbx_k9unit` into your server's `resources` folder.
2. **Run the SQL migration before first start.** Import
   `qbx_k9unit/sql/install.sql` against your database (phpMyAdmin, HeidiSQL,
   the `mysql` CLI, etc.) — this resource does not auto-execute it. See
   [Database](#database) below for what it creates. Every `CREATE TABLE` in
   it is `IF NOT EXISTS`, so it is safe to re-run against a database that
   already has some or all of these tables.
3. Add to `server.cfg`, after the five dependencies above:
   ```
   ensure qbx_k9unit
   ```
   There is no other load-order requirement — `fxmanifest.lua`'s own
   `dependencies` block is what enforces the five resources above starting
   first; nothing else needs to be sequenced around it.
4. Open `config.lua` and adjust it to your server before going live — at
   minimum:
   - `Config.Departments` — your actual job names and certifier grade
     thresholds (shipped defaults: `police`, `sheriff`, `bcso`).
   - `Config.Peds` — the dog models you want recognized (defaults to four
     native canine models).
   - `Config.K9Vehicles` — the vehicle models your K9 can load into.
5. Certify your first handler — see
   [How certification works, day one](#how-certification-works-day-one)
   below.
6. **Every flag is already `true` as of 2026-08-25** — the "if you plan to
   enable any flag beyond the five" framing below no longer applies. Read
   every row in the [feature flag reference](#config-features-full-reference)
   below regardless, since several carry a caveat worth understanding now
   that the feature is live, and turn `BoneSweepDevTool` back off
   immediately if this is a real server (see the top-of-file notice).

## Database

**Minimum engine: MySQL 5.7.8+ or MariaDB 10.2+.** `k9_certifications`'
`active_cert_key` column is a `GENERATED ALWAYS AS (...) VIRTUAL` column,
which older engine versions don't support — a real attempt against MySQL
5.6 left the schema only half-built partway through `sql/install.sql`.
Confirm your database engine and version before running the migration
below.

`sql/install.sql` creates four tables. **Verification note (2026-08-24):**
every `MySQL.*` call across `server/*.lua` was grepped and cross-checked
against this file; all four tables a running resource actually queries have
a matching `CREATE TABLE IF NOT EXISTS`. There is no missing-table gap as of
this pass. (A separate `db-schema` agent may be working in `sql/`
concurrently with this documentation pass — re-check this section against
the file's current contents if `sql/install.sql` has changed since
2026-08-24.)

**Correction to an earlier draft of this section:** it previously claimed
`server/tenure.lua` queries a `tenure_bonus_tier_granted` column on
`k9_partnerships` that does not exist in `sql/install.sql`, and that the
file wasn't loaded by `fxmanifest.lua`. Both are now false — verified
against the current tree: `sql/install.sql`'s `k9_partnerships`
`CREATE TABLE` already includes `tenure_bonus_tier_granted` (with
`sql/migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql`
available for an existing database that predates it), and `server/tenure.lua`
is listed in `fxmanifest.lua`'s `server_scripts`. `server/tenure.lua`'s
queries remain `pcall`-wrapped regardless, so a database that hasn't run
migration 0003 yet still degrades to a silent no-op rather than an error —
that defensive behavior was never the bug, only the "column/file don't
exist" framing was.

### `k9_certifications`

The **sole source of truth** for who currently holds an active K9
certification. Append-mostly: granting `INSERT`s a row, revoking `UPDATE`s
the existing active row to `active = 0` (never deletes) — full grant/revoke
history per citizen/job is always reconstructable, including revocations
issued while the target was offline.

```sql
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`        VARCHAR(50)  NOT NULL,
  `job`              VARCHAR(50)  NOT NULL,      -- department job name at grant time
  `granted_by`       VARCHAR(50)  NOT NULL,      -- citizenid of the certifying officer
  `granted_at`       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`       VARCHAR(50)  DEFAULT NULL,  -- citizenid, or the sentinel 'system:job_change'
  `revoked_at`       DATETIME     DEFAULT NULL,
  `active`           TINYINT(1)   NOT NULL DEFAULT 1,
  `active_cert_key`  VARCHAR(105) GENERATED ALWAYS AS (...) VIRTUAL,  -- see install.sql for the full expression
  PRIMARY KEY (`id`),
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),
  KEY `idx_job_active` (`job`, `active`),
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Notes for anyone querying this directly (e.g. an admin panel):

- At most **one active row** per `(citizenid, job)` pair, enforced both in
  application logic and by the `uq_one_active_cert_per_job` unique index.
- `revoked_by` can hold a real citizenid **or** the literal string
  `'system:job_change'` (auto-revoked because the holder left the
  department — see [Automatic revocation](#automatic-revocation-on-leaving-the-department)).
- List currently certified handlers in a department:
  `SELECT citizenid, granted_by, granted_at FROM k9_certifications WHERE job = ? AND active = 1;`
- No foreign key to a `players` table, by design — this migration has no
  install-order dependency on `qbx_core`'s own schema.

A read-only mirror, `metadata.k9certified` (boolean), is also written to the
player's `qbx_core` metadata on every grant/revoke for **client-side
HUD/badge display only**. It is never read by any server-side authorization
check.

### `k9_search_log`

Append-only audit trail for every completed Phase 2 contraband search
(`server/search.lua`), one row per attempt that reached a real inventory
read (`found`/`clean`/`search_failed`). Early rejections
(`on_cooldown`/`too_far`/etc.) are never logged. Exists for dispute
accountability ("did this K9 actually search my vehicle") — nothing in this
resource reads it back to make an access decision.

### `k9_partnerships`

Backs `Config.Features.HandlerPartnership` (`server/partnership.lua`). At
most one **active** row per citizenid, in either the `k9_citizenid` or
`handler_citizenid` column, enforced by two independent unique indexes plus
an application-level mutex. A foundation table only — nothing in this
resource currently reads it to drive a combat consequence (see
[Config.Features.HandlerDownDefense](#configfeatureshandlerdowndefense)
below for the one exception, which does now exist).

### `k9_progression`

One row per citizenid (`xp` column, atomically upserted via
`INSERT ... ON DUPLICATE KEY UPDATE`), backing
`Config.Features.XPProgression` (`server/progression.lua`). Survives a
department change, unlike `k9_certifications`. This table was missing from
an earlier draft of this migration — every query against it in
`server/progression.lua` is `pcall`-wrapped, so a missing table never
crashed the resource, it just meant XP never survived a restart. It is
present in the current `sql/install.sql`; re-run the migration once against
an existing database if `XPProgression` was ever enabled before this table
existed.

## How certification works, day one

Access to every K9 feature (radial menu, leash, vehicle load) requires,
checked **server-side on every gated action**:

1. The player's current `job.name` is a key in `Config.Departments`, **and**
2. The player holds an **active** row in `k9_certifications` for that exact
   job (or the department's optional `autoAccessGrade` bypass applies).

Nothing is cached client-side as a one-time pass; a modified client cannot
bypass this by lying about its own job, rank, or model.

**Bootstrapping a fresh server** (nobody is certified yet):

1. A high-rank officer creates/switches to a character using a model in
   `Config.Peds` (e.g. `a_c_shepherd`).
2. They get hired into a department listed in `Config.Departments`, at or
   above that department's `certifierGrade` (or as the boss,
   `job.isboss == true`).
3. They run `/k9certify <their own server id>` — self-certification is
   **command-only**; the ox_target "Certify K9 Handler" option explicitly
   excludes targeting yourself. Requires `Config.AllowSelfCertification`
   (default `true`).
4. They can now certify every other K9-model officer in the department the
   normal way (ox_target or `/k9certify [id]`).

If `Config.AllowSelfCertification` is `false`, a second certifier-eligible
officer must always be online to grant the first certification.

**Granting** (`/k9certify [server id]` or the ox_target option) requires,
all re-verified server-side:

- The granter's job is a key in `Config.Departments` and
  `job.grade.level >= certifierGrade` for that department, or they are the
  department boss.
- The target's job is a key in `Config.Departments` — **any** configured
  department, not necessarily the same one as the granter (cross-department
  certifying is allowed by design).
- The target is online.
- Granter and target are within `Config.CertifyProximityMeters` (default
  `5.0`m) of each other, measured server-side — skipped only for
  self-certification.
- The target's **live** ped model (read server-side) is one of
  `Config.Peds`. Applies to granting only.

**Revoking** uses the same certifier-eligibility and proximity rules, but
does **not** check the target's model. Two paths: `/k9decertify [server id]`
(target must be online) or `/k9decertifyoffline [citizenid] [job]` (for a
genuinely disconnected target; refuses and redirects if the citizenid
resolves to an online player, closing a proximity-check bypass).

## Automatic revocation on leaving the department

A server-side handler on `QBCore:Server:OnJobUpdate` automatically revokes a
K9's active certification the moment their `job.name` changes away from the
department it was granted for.

- Recorded with `revoked_by = 'system:job_change'`.
- A grade change **within** the same department does not trigger a revoke.
- Certification does not come back automatically on rehire — a fresh grant
  is always required.
- If the player is the K9-role party in an active leash pairing at the
  moment their cert is revoked (manual, offline, or automatic), that leash
  is force-detached immediately.

## Config.Features — full reference

All configuration lives in `config.lua`. **Every numeric value in every
Phase 2+ config table is an unreviewed placeholder pending a balance pass —
this is called out per-section below where it matters most (combat,
economy).**

### Phase 1 — enabled by default

| Flag | Default | What it gates | Prerequisite |
|---|---|---|---|
| `LeashMechanics` | `true` | The "Attach Leash" ox_target option and radial item; gates whether a leash pairing can ever form. | — |
| `RadialMenu` | `true` | Whether the "K9 Unit" ox_lib radial submenu is registered at all. | — |
| `VehicleEntryExit` | `true` | The "Load/Release K9" ox_target options and the radial "Enter/Exit Vehicle" item. | — |
| `BasicBarkSounds` | `true` | The radial "Bark" item and the server's `relayBark` handler. Plays a real, licensed bark sound — see [Bark sounds](#bark-sounds-now-ship-with-real-audio) below. | — |
| `AgilityBasicJump` | `true` | When `true`, jump/crouch use native locomotion unmodified. When `false`, jump/crouch are actively **disabled** for a K9-modeled player. | — |

### Phase 2 — tracking & vision (shipped `false`; all now `true`, see top-of-file notice)

| Flag | Default | What it gates | Prerequisite / caveat |
|---|---|---|---|
| `ScentTracking` | `false` | "Track Scent" — trail source is a dropped item, logged via `exports.ox_inventory:registerHook('swapItems', ...)`. | **Do a one-time dev-server check before enabling in production.** The hook's exact payload shape was confirmed by reading `ox_inventory`'s source, not by an independent test against a live install. Log the hook payload once and confirm field names match before trusting this in production. |
| `BloodTracking` | `false` | "Track Blood" — trail source is the most recent logged damage event. | Requires the (payload-less, coordinate-only) damage relay in `server/tracking.lua`. |
| `GunpowderSniffing` | `false` | "Track Gunpowder" — trail source is the most recent logged weapon-fire location. | Same relay mechanism as Blood. |
| `WaterTrackingDecay` | `false` | Modifies whichever trail is currently rendering when it crosses water. | Only takes effect if Scent/Blood/Gunpowder is also enabled and a trail is drawing. |
| `SearchZones` | `false` | "Search Vehicle"/"Search Person" ox_target options; reads a target's real `ox_inventory` contents server-side. | `Config.SearchContrabandItems` ships **placeholder item names** — replace with your own economy's real contraband items before enabling. |
| `ContrabandAlerts` | `false` | Broadcasts a sound/reaction to bystanders within `Config.SearchZones.alertBroadcastRadius` when a search finds contraband. | Requires `SearchZones` also enabled; without it, search still works but reports privately to the searcher only. |
| `ThermalVision` | `false` | `K` key (default) toggles `SetSeethrough`. | Gated on playing a K9-modeled character, not on certification. |
| `NightVision` | `false` | `J` key (default) toggles `SetNightvision`. | Same as Thermal; mutually exclusive with it. |
| `DoorInteraction` | `false` | "Scratch to Alert" (server round-trip, cooldown-gated) and "Nudge Door" (100% client-local cosmetic push — never touches lock state). | `Config.DoorInteraction.nudgeRequiresUnlocked` is enforced only as a resource-start assertion; it must never become a real lock-state branch. |

### Phase 3 — combat & agility (shipped `false`; all now `true` — the two open safety questions below are NOT resolved by that, see top-of-file notice and `DEVELOPER_REFERENCE.md` §17)

| Flag | Default | What it gates | Prerequisite / caveat |
|---|---|---|---|
| `AgilityAdvanced` | `false` | Fence/window vault approximation via capsule-sweep raycast. | No PvP/trust-boundary caveat — only affects the acting K9's own ped. |
| `BiteAndHold` | `false` | Suppresses a target's sprint/weapon-fire input for up to `Config.Combat.BiteAndHold.maxDurationMs` (15000ms). | **See combat trust-boundary caveat below. Do not enable on a live server without reading it.** |
| `NonLethalTakedown` | `false` | Forces a ragdoll + temporary damage suppression on a fast-moving target. | Same caveat as `BiteAndHold`. |
| `PropDragging` | `false` | Attaches and drags a target entity, server-enforced 30m max drag distance. | Same caveat as `BiteAndHold`. |
| `HandlerDownDefense` | `false` | Notifies a K9's active partner (see `HandlerPartnership`) when the handler is likely under attack, with an optional pre-selected target for a manually-confirmed `BiteAndHold`/`NonLethalTakedown` request. | **Now implemented** (`server/defense.lua` + `client/defense.lua`) — a UI/auto-targeting convenience only, never an AI takeover; requires `HandlerPartnership` to have an active partner to notify. |
| `HandlerPartnership` | `false` | Mutually-consented "Partner Up"/"Break Partnership" registry, DB-backed, survives disconnect/restart. | Currently the only Phase 3 flag considered safe to enable on its own — see its own section below. |

**The combat trust boundary, stated plainly:** for a **player** target, the
actual restraining effect (input-disable, forced ragdoll, move-rate
reduction) runs on *that player's own client*, relayed there by the server.
A modified client can simply ignore the relayed event — this resource's own
player-facing text is worded as best-effort for exactly this reason, and no
server-side check ever assumes the effect landed. Non-compliance detection
(`Config.Combat.NonComplianceDetection`, default `enabled = true`) samples
target position every 500ms and flags a likely violation via `'log'` or
`'notify_staff'` (never `'auto_kick'`/`'auto_ban'`) — **this is logging and
staff notification only; no server-authoritative consequence of any kind is
ever conditioned on a compliance signal.** A flagged violation never ends
the hold early, denies a cooldown refund, or blocks a future request.
`client/combat.lua`'s event handlers are gated per-mechanic (closing a real
gap where a modified client used to be able to trigger an effect like
indefinite self-invincibility with zero server contact even with every flag
`false`), but once a mechanic is enabled, an individual handler still does
not verify a given invocation actually came from the server. **`BiteAndHold`,
`NonLethalTakedown`, and `PropDragging` are enabled right now** (see the
top-of-file correction notice) — this is no longer a "before you enable"
warning, it's a description of a live, unresolved property of your running
server. See `DEVELOPER_REFERENCE.md` §17's D3 for the specific open question about
whether the origin-guard half of this holds up, and D13 for a related,
separate griefing exposure once `FearStressSystem` (also enabled) is
combined with combat.

### Phase 4 — inventory, progression, vitality (shipped `false`; all now `true`, see top-of-file notice)

| Flag | Default | What it gates | Prerequisite / caveat |
|---|---|---|---|
| `K9Inventory` | `false` | A per-K9 `ox_inventory` gear stash, "Open K9 Gear" ox_target option. | `Config.K9Inventory.accessScope` is hard-locked to `'department'` (any player in a configured department, any grade). There is **no** real owner-only mode — `ox_inventory`'s stash access is gated exclusively by `groups`, never by the `owner` argument, so a previous `'ownerOnly'` config value never actually restricted access and has been removed. `Config.K9Inventory.allowedItems` (default `nil` — no whitelist) is **now genuinely enforced**, correcting an earlier draft of this table that said it "has no effect even if set": `server/inventory.lua` registers a real, pre-mutation `exports.ox_inventory:registerHook('swapItems', ...)` veto that rejects any item not on the list *before* it ever lands in the stash (confirmed against `ox_inventory`'s own source — returning `false` from the hook stops the write, not an after-the-fact undo), printing one warning and disabling the whitelist (not the whole stash) if the target `ox_inventory` build lacks `registerHook`. |
| `K9Medkit` | `false` | "Treat K9" ox_target interaction, consumes a real `ox_inventory` item to restore health. | Authorized by job (a configured department, `Config.K9Medkit.emsJobs`, default `{ 'ambulance' }`, or an override hook) — not by the user's own K9 certification. |
| `HealthStaminaHUD` | `false` | A passive vitality HUD (`client/hud.lua`, this resource's first NUI surface). | Hunger/thirst fields read from `qbx_core` metadata at **medium confidence** — field names/scale not independently verified against a live install; confirm before enabling in production. |
| `FatigueSystem` | `false` | Stamina-linked stat; sprinting decays it, idle regenerates it; low fatigue reduces move speed. | Part of the shared wellbeing subsystem (one tick, one store) — see below. Idle regen near a configured rest source (`Config.Wellbeing.Fatigue.restSources`, default `{ 'water_bowl' }`) is now genuinely faster (`restRegenPerTick`, default `4.0`/tick vs `idleRegenPerTick`'s `1.0`) — matched server-side every tick against `GetAllObjects()`/`GetAllVehicles()` within `restRadius` (never a client-claimed "I'm near one" position), not the config-comment-only placeholder an earlier pass left this as. `config.lua`'s own comment on this field still reads "NOT WIRED THIS PASS" as of this writing — stale; flagged for `config.lua`'s owner to correct, not edited here (out of scope for this doc pass). |
| `MoodSystem` | `false` | Damage decays it; "Pet K9"/"Feed K9" restore it; low mood reduces move speed. | Same subsystem. |
| `FearStressSystem` | `false` | Nearby gunfire raises it; above a threshold it imposes temporary command-refusal. | Only meaningful once a real consumer of `IsHesitating()` is also enabled (currently only the still-disabled combat flags). |
| `DistractionSystem` | `false` | A thrown meat-bait item or ultrasonic whistle briefly distracts nearby K9s. | Deliberately usable by **any** player — not gated on K9 UI access. `Config.Wellbeing.Distraction.flashbangImmune`'s real, callable half now exists: `IsFlashbangImmune(citizenid)` is a genuine resource-global accessor (same contract as `IsHesitating`/`IsDistracted`), correcting an earlier draft that called this "aspirational config only, not implemented." What remains genuinely unbuilt is the *consumer* side — no companion flashbang/stun resource with a confirmed event shape exists for this codebase to listen to and suppress, so nothing calls the new accessor yet; a future flashbang resource wanting to honor immunity would call `IsFlashbangImmune(citizenid)` before applying its own stun effect. |
| `InjuryLimping` | `false` | Damage decays it; blocks sprint/jump input client-locally below a threshold; restored by `K9Medkit`. | Client-local enforcement, not a server-side boundary. |
| `XPProgression` | `false` | Server-authoritative XP per K9 citizenid, persisted in `k9_progression`. | See its own section below for award triggers and anti-farming measures. |
| `ContrabandScreenFX` | `false` | A brief self-only `SetTimecycleModifier` screen effect for the K9's **own handler** (the searcher, never the searched player or a bystander) on a contraband find at or above a configured alert tier. | **Now fully wired end-to-end**: `client/screenfx.lua` is loaded (`fxmanifest.lua`), and `server/search.lua`'s search-success path fires the `qbx_k9unit:client:applyContrabandScreenFx` event it listens for. An earlier draft of this table said the client file was inert with no server trigger — both halves are real now. Still ships `false`, and `Config.ContrabandScreenFX.modifierName` remains an unverified candidate timecycle-modifier name (harmless no-op if wrong, per this resource's usual convention for an unconfirmed asset name) — see [Known issues](#known-issues--historical-now-resolved) for what used to be wrong here. |

### Phase 5 — audio/props/camera R&D (shipped `false`; all now `true`, including `BoneSweepDevTool` — see top-of-file notice, that one must not stay on)

| Flag | Default | What it gates | Prerequisite / caveat |
|---|---|---|---|
| `DeployableKennel` | `false` | Places a world kennel object (`/k9deploykennel`); server computes the spawn point and independently re-validates the placed object. Reachable from the radial menu ("Deploy Kennel") as well as the command. | `Config.DeployableKennel.propModel` was `'prop_doghouse_01'` — **refuted and replaced 2026-08-25**. That name traced to a single unverified third-party config default and does not appear in a 5,171-entry live object database (its screenshot URL 404s); it has been replaced with `'prop_dog_cage_01'` (hash `379820688`), which **does** appear in that database with a real rendered screenshot. Still worth eyeballing on your own dev server before enabling — a database entry with a screenshot is checkable evidence, not an in-engine confirmation. `fallbackPropModel` (`'prop_tennis_ball'`, confirmed real) is used automatically if the primary model fails to load, so a bad `propModel` degrades to "an oddly-shaped real object" rather than a silent failure. |
| `AdvancedBarkRadial` | `false` | Turns the single "Bark" radial item into a 3-way Alert/Aggressive/Calm submenu. | Requires `BasicBarkSounds` also enabled. All three variants now have real audio behind them — see [Bark sounds](#bark-sounds-now-ship-with-real-audio) below. |
| `ProximityAudioFX` | `false` | Ambient K9 presence audio that scales with a listener's live distance, built on `client/audio.lua`'s bridge. | `client/proximityaudio.lua` and `Config.ProximityAudioFX` are real and **registered in `fxmanifest.lua`** — reachable the moment this flag is `true`, and audible: its ambient growl now has a real `.ogg` file behind it — see [Bark sounds](#bark-sounds-now-ship-with-real-audio). |
| `PropAttachments` | `false` | Cosmetic prop (vest/harness) toggle on a K9's own ped, reachable from the radial menu ("Toggle K9 Vest"). | Real client+server code, config, and radial entry all exist and are registered. `Config.PropAttachments.boneIndex` is still the root-bone (`0`) placeholder pending the dev-only bone-index sweep (`BoneSweepDevTool`, `client/bonetool.lua`/`server/bonetool.lua`) — degrades to "visibly attached at the wrong point," never a crash. |
| `FetchMechanic` | `false` | Throw a ball, the K9 fetches it, the handler collects it back manually — see `DEVELOPER_REFERENCE.md` §14.4.3. Reachable from the radial menu ("Fetch": Throw/Drop, Recall). | Real client+server code (`client/fetch.lua`/`server/fetch.lua`) is registered and reachable. Ships in `mouthCarryMode = 'delete-and-reappear'` mode rather than a real mouth-attach pending the same bone-index sweep as `PropAttachments`. Handler-disconnect and carrier-disconnect cleanup (`playerDropped`) end an in-progress cycle rather than leaking a networked ball into the world permanently. |
| `CameraFeedPiP` | `false` | No code exists, and **confirmed impossible with currently-available natives**: there is no native to render a secondary camera feed into an NUI texture. Document this as impossible-today, not "coming soon." | — |

#### Bark sounds now ship with real audio

**Corrected 2026-08-25 — this section used to describe every bark as
silent. That's no longer true for any of them, though the reason is worth
getting right.** Every bark still also calls `PlaySoundFromEntity` with a
placeholder RAGE soundset name (`'Bark'`, `'Bark_Alert'`,
`'Bark_Aggressive'`, `'Bark_Calm'`) that resolves to nothing — no real RAGE
audio bank exists for those names, and that half hasn't changed. **What
changed is the second, independent path**: the NUI audio bridge below now
has a real Ogg Vorbis file behind every one of those same four sounds, plus
`ProximityAudioFX`'s ambient growl (`'Growl_Ambient'`) — five files total,
audible today. The player-audible result is the same either way (a real
sound plays), but if you're the one debugging why a *new* sound name is
silent, know that this resource has two independent audio paths and only
one of them (the NUI bridge, `.ogg` files) has ever had real audio behind
it. **All five `.ogg` files this resource can play now ship with it**,
under `html/sounds/`, and are listed in `fxmanifest.lua`'s `files{}` block.

The NUI audio bridge (`client/audio.lua` + matching handlers in
`html/app.js`) plays each file via Web Audio, with distance-based gain.
`client/main.lua`'s `PlaySoundOnNetworkEntity` (the function every bark
routes through) calls `client/audio.lua`'s `PlayK9Sound` immediately after
its `PlaySoundFromEntity` native call, guarded by the same
`type(PlayK9Sound) == 'function'` existence check used everywhere else in
this resource for a soft cross-file dependency. `client/proximityaudio.lua`
is a second, independent consumer of the same bridge for `ProximityAudioFX`.

| File | Used for |
|---|---|
| `html/sounds/bark.ogg` | Phase 1 generic bark |
| `html/sounds/bark_alert.ogg` | `AdvancedBarkRadial` "Alert Bark" |
| `html/sounds/bark_aggressive.ogg` | `AdvancedBarkRadial` "Aggressive Bark" |
| `html/sounds/bark_calm.ogg` | `AdvancedBarkRadial` "Calm Bark" |
| `html/sounds/growl_ambient.ogg` | `ProximityAudioFX` ambient K9 presence (looping) |

Every one of these five files carries a real attribution obligation — none
is public domain, and every source, license, and required credit line is
recorded in `html/sounds/CREDITS.md`. That obligation has already been
satisfied for this resource's own default install; read
`html/sounds/CREDITS.md` before redistributing this resource yourself, or
before replacing any of these five files with your own audio (follow that
file's own pre-drop checklist and add your own source/license entry rather
than dropping a file in with no record of where it came from).

### `Config.Features.HandlerPartnership`

`boolean`, default `false`. Gates a mutually-consented "Partner Up"/"Break
Partnership" registry (`server/partnership.lua`, `client/partnership.lua`,
`k9_partnerships` table). Unlike leash, a partnership is **DB-backed and
survives a disconnect or resource restart**.

- Either party uses "Partner Up" on the other; the target gets an
  accept/decline prompt. Eligibility is re-validated a second time on
  accept. The K9-role party needs `HasK9Access`; the handler-role party
  needs only `job.name` in `Config.Departments` — no certifier-grade
  hierarchy, no requirement that the handler hold their own certification.
- At most one active partnership per citizenid, in either role, enforced by
  two DB unique indexes plus an in-process mutex.
- Either party can end it at any time with zero consent required.
- Losing certification, changing departments, or otherwise leaving the
  department automatically tears down an active partnership, regardless of
  this flag's current value.
- `Config.Partnership.ProximityMeters` (default `5.0`m), `.RequestTTLMs`
  (default `30000`ms), `.RequestCooldownMs` (default `1000`ms).
- **No longer foundation-only.** `HandlerDownDefense` (above) reads this
  registry to know who to notify, and `DEVELOPER_REFERENCE.md` §12's Recall mechanic
  (`Config.Features.Recall`, `server/recall.lua` + `client/recall.lua`, the
  `/k9recall` command) is also real, implemented code now — an earlier
  draft of this section said Recall "still has zero code," which is no
  longer true. Recall is the handler's escape hatch for any active
  bite/takedown/drag their partnered K9 is holding, and is deliberately
  never gated behind `HasK9Access`/`CanShowK9UI` on either party, since a
  decertified handler must still be able to call their dog off mid-engagement.
- **Disclosed reconnect gap**: nothing re-syncs a reconnecting client's own
  view of an already-established partnership — `IsPartnered()`/
  `GetPartnerServerId()` (client-side) can under-report until a fresh
  consent-handshake event reaches that client. This only affects the
  "Partner Up" option's own display check; the server's own eligibility
  check still authoritatively rejects a redundant request either way, and
  `BreakPartnership()` is unconditional regardless of local cache state.

### `Config.Features.XPProgression`

`boolean`, default `false`. Server-authoritative XP per K9 citizenid
(`server/progression.lua`), persisted in `k9_progression` (survives a
department change, unlike certification). `Config.XP.awards`:

- `searchContrabandFound` (default `25`) — a successful contraband search.
- `trackSourceResolved` (default `10`) — awarded only once the K9 actually
  **arrives** within `Config.XP.trackArrivalRadius` (`3.0`m) of a resolved
  source within `Config.XP.trackArrivalTTLMs` (`60000`ms) — not on the trail
  merely resolving, and gated on the K9 being at least 15m from the source
  at resolve time, to prevent farming.
- `biteHoldSuccess` (default `20`) / `takedownSuccess` (default `30`) —
  wired to real call sites in `server/combat.lua`, but dormant in practice
  since `BiteAndHold`/`NonLethalTakedown` ship `false`.

Crossing a `Config.XPTiers` threshold applies that tier's
`speedMultiplier`/`scentRangeMultiplier` and pushes a one-time notification.
`Config.XP.scopePerCitizenidOrJob` only supports `'citizenid'` today.

### `Config.Features.HighCommand` — live

`boolean`, `true` in `config.lua`, alongside the `Config.HighCommand`
table and a `highCommandGrade` field on every `Config.Departments` entry.

This IS a working feature as of 2026-08-25. `server/highcommand.lua`
exists, is listed in `fxmanifest.lua`, and `/k9givexp` is a real command.
(An earlier revision of this section said the opposite; it was written
during the window between the config landing and the code landing.)

A caller at or above their department's `highCommandGrade`, or holding
`job.isboss`, bypasses every other rank gate in this resource:
`certifierGrade`, `auditGrade`, the bone dev tool's boss check, and the
K9 certification requirement itself. `nil` disables the tier for that
department and means "no such rank exists here", never "everyone
qualifies" — the check fails closed on a nil, a non-number, or a
malformed grade.

Note this is the only feature flag whose real effect is to grant an
in-game job rank WRITE access to the XP economy, so set the grade
deliberately. Every grant is logged with granter, target, amount and
resulting total.

`config.lua`'s own comment block for `Config.HighCommand` already
describes the intended design in detail: a per-department senior-rank tier
that bypasses every other rank check in this resource and can mint XP
directly, but deliberately does **not** grant the ability to run arbitrary
server commands (that would turn an in-game promotion into full
server-wide control, which this resource's own author considered and
rejected). Read that comment block directly for the full reasoning before
this section is updated with real behavior once `server/highcommand.lua`
lands.

## Public API (exports)

**This resource's first exports, added 2026-08-24.**

> **These exports are live.** An earlier draft of this section warned that
> `server/exports.lua`/`client/exports.lua` existed on disk but were not
> listed in `fxmanifest.lua`, so calling any export below would fail with
> "no such export." That is no longer true — both files are now in
> `fxmanifest.lua`'s `server_scripts`/`client_scripts` (each self-registers
> via a plain `exports('name', fn)` call at load time, so no
> `server_exports`/`client_exports` manifest key is needed on top of that).
> Every export documented below is callable from another resource today.

Both files share these design rules: every export is **read-only** (no
grant/revoke/award/mutation is exposed), every table return is a **fresh
copy** (never a live reference into this resource's internal state), every
export **fails closed** (a bad argument or an internal error returns the
same "unknown state" default the resource already uses elsewhere — `false`,
`0`, or `nil` — never an uncaught error), and every export **re-derives**
its answer from the same server-authoritative source the internal code
already uses rather than trusting a caller-supplied value as fact.

Server and client each carry their **own independent** `GetAPIVersion()` —
they are two separate contracts, not one mirrored number, and have already
diverged: **server is `{ major = 1, minor = 0, patch = 0, string = '1.0.0' }`**;
**client is `{ major = 1, minor = 1, patch = 0, string = '1.1.0' }`**
(bumped for the three new client exports below). A consumer should call
each side's own `GetAPIVersion()` independently and branch on `.major` — an
additive change bumps `minor`, a breaking change (removed/renamed export,
narrowed return shape) bumps `major`.

### Server exports (`server/exports.lua`)

| Export | Signature | Returns |
|---|---|---|
| `GetAPIVersion` | `()` | `{ major, minor, patch, string }` |
| `HasK9Access` | `(source: number)` | `boolean` — server-authoritative: can this **currently-connected** player use K9 features right now. Not gated on any `Config.Features` flag. |
| `IsConfiguredK9Model` | `(modelHash: number)` | `boolean` — is this a hashed model in `Config.Peds`. Pure roster truth. |
| `IsK9Department` | `(jobName: string)` | `boolean` — is this job a key in `Config.Departments`. |
| `GetActivePartnerCitizenId` | `(citizenid: string)` | `partnerCitizenid: string?, isK9: boolean?` — `nil, nil` if not currently partnered. Not gated on `HandlerPartnership`; reflects real cache state regardless of the flag. |
| `IsActivePartnerOf` | `(citizenid: string, allegedPartnerCitizenid: string)` | `boolean` |
| `GetXP` | `(citizenid: string)` | `number` — raw accumulated XP, `0` if unknown/invalid. Not gated on `XPProgression`. |
| `GetXPTier` | `(citizenid: string)` | `{ xp, label, speedMultiplier, scentRangeMultiplier }` — always a fresh copy; defaults to the base tier (`Config.XPTiers[1]`) copy for an unknown citizenid. Corrected 2026-08-25: this field was previously (and wrongly) documented as `scentRange`; `Config.XPTiers` itself has always used `scentRangeMultiplier`. |
| `IsFeatureEnabled` | `(featureKey: string)` | `boolean?` — reads `Config.Features[featureKey]` directly; `nil` (not `false`) if `featureKey` isn't a recognized key, so a caller can distinguish "off" from "unrecognized." |

**No mutation export exists** (no `GrantCertification`, `AwardXP`,
`ForceDetachLeashForSource`, etc.) — deliberately, so a bug in an
integrating resource cannot bypass this resource's own eligibility/
proximity/cooldown checks. There is still no **exported** `k9_search_log`
read-back or "list all K9 citizenids"/"list all active partnerships"
accessor — both would require new query/authorization logic
`server/exports.lua`'s own header deliberately did not invent unreviewed.
(As of this pass there is now other, police-job-rank-gated precedent for
reading `k9_search_log` back inside this resource — see `server/admin.lua`'s
`/k9auditsearch` command under [Commands](#commands), corrected 2026-08-25
to no longer use ACE at all — but that is still a console/rank-authorized
admin command, not a public export any resource can call, and does not by
itself justify adding one without the same access-scope review
`server/exports.lua`'s header calls for.)

**All six outbound events are now wired and firing.** An earlier draft of
this section said a `qbx_k9unit:events:*` namespace
(`certificationGranted`, `certificationRevoked`, `partnershipEstablished`,
`partnershipEnded`, `searchCompleted`, `xpTierReached`) was specified in
`server/exports.lua`'s header but that none of them fired yet. That is no
longer true — `server/certifications.lua`, `server/partnership.lua`,
`server/progression.lua`, and `server/search.lua` each now call a shared
`FireOutboundEvent(...)` helper at the exact success points
`server/exports.lua`'s header originally specified (grant, both revoke
paths and the auto-revoke-on-job-change path, partnership established,
partnership ended, search completed, and an XP tier crossing
respectively). `AddEventHandler` for any of these six today and they will
fire under real gameplay conditions — not gated on any `Config.Features`
flag, since certification/search/partnership/XP are this resource's core
mechanics rather than phase-numbered toggles.

### Client exports (`client/exports.lua`)

Client-side state is **never a security boundary** in this resource (a
modified client can always lie to itself) — these exports are display/UI
coordination state for another client-side resource sharing the same
player's session (e.g. a vision/goggle resource checking
`IsThermalVisionActive()` before stacking its own effect, or a HUD resource
hiding itself while `CanShowK9UI()` is true). For anything
security-relevant, use the **server** export of the same name instead.

| Export | Signature | Returns |
|---|---|---|
| `GetAPIVersion` | `()` | `{ major, minor, patch, string }` |
| `HasK9Access` | `()` | `boolean` — yields on a server round-trip (debounced, ~1s cache TTL). Local-player check only. |
| `IsOwnModelK9` | `()` | `boolean` — pure client-side display check. |
| `CanShowK9UI` | `()` | `boolean` — the same combinator (`IsOwnModelK9()` AND `HasK9Access()`) every other client file in this resource gates its own UI on. Yields, same as `HasK9Access`. |
| `IsLeashed` | `()` | `boolean` |
| `IsInK9Vehicle` | `()` | `boolean` |
| `IsPartnered` | `()` | `boolean` — non-yielding local cache read; see the `HandlerPartnership` reconnect-gap caveat above. |
| `GetPartnerServerId` | `()` | `number?` |
| `GetCurrentXPTier` | `()` | `{ xp, label, speedMultiplier, scentRangeMultiplier }?` — `nil` until the first server-pushed tier snapshot arrives this session; always a fresh copy. |
| `IsTracking` | `()` | `boolean` |
| `GetActiveTrackType` | `()` | `'scent'\|'blood'\|'gunpowder'\|nil` |
| `IsThermalVisionActive` | `()` | `boolean` |
| `IsNightVisionActive` | `()` | `boolean` |
| `IsBiteHoldEngaged` | `()` | `boolean` |
| `IsDragEngaged` | `()` | `boolean` |
| `HasFreshDefensePrompt` | `()` | `boolean` — **added in 1.1.0.** Is there a still-fresh (not yet expired) `HandlerDownDefense` prompt pending for the local player's own K9 right now. Local UI state, not a security check, same posture as `CanShowK9UI()`. |
| `GetDefenseSuggestedTargetNetId` | `()` | `number?` — **added in 1.1.0.** The server-suggested hostile netId attached to the current fresh defense prompt, if any. |
| `IsFetchCarryEngaged` | `()` | `boolean` — **added in 1.1.0.** Is the local K9 currently mid-fetch-carry (`FetchMechanic`). Same shape/justification as `IsBiteHoldEngaged`/`IsDragEngaged` — an animation-management resource may want to know before doing something that would visibly conflict with it on the same ped. |

**No action export exists** (`RequestPartnerUp`, `RequestLeashAttach`,
`RequestBiteHold`, `ToggleThermalVision`, etc.) — every self-initiated
action in this resource has its own consent/proximity/cooldown context tied
to this resource's own UI flow (radial menu, ox_target option) that an
external resource driving it directly would bypass.

## Known issues — historical, now resolved

**Every file on disk is loaded, and every file that needed a caller has
one, as of this pass** — verified by a direct read of the current
`fxmanifest.lua`, not inferred from an earlier note. This section used to
carry a growing table of "real code, zero reachability" files while this
resource's manifest was still catching up with its own source tree; that
table is retired below rather than deleted outright, since a future reader
hitting a stale copy of this file benefits more from seeing what changed
than from a silent disappearance.

**What used to be listed here, and its current status:**

- `server/exports.lua`, `client/exports.lua`, `client/audio.lua`,
  `client/screenfx.lua`, `server/tenure.lua`, `server/admin.lua` — an
  earlier revision listed these six as written but not loaded. All six have
  been in `fxmanifest.lua` for some time now.
- `client/propattachment.lua`/`server/propattachment.lua`,
  `client/fetch.lua`/`server/fetch.lua`, `client/proximityaudio.lua`,
  `client/bonetool.lua`/`server/bonetool.lua` — the Phase 5 R&D batch. All
  five files/pairs are registered in `fxmanifest.lua`. Their flags
  (`PropAttachments`, `FetchMechanic`, `ProximityAudioFX`,
  `BoneSweepDevTool`) still ship `false` by default — that is a feature
  being off, not a file failing to load.
- `client/audio.lua` — the last item in this table, and the last one
  corrected: an earlier revision said this file's NUI bark/ambient bridge
  had "no caller yet inside the manifest." That is now false —
  `client/main.lua`'s bark relay calls `PlayK9Sound` directly (see
  [Bark sounds](#bark-sounds-now-ship-with-real-audio) above), and
  `client/proximityaudio.lua` is a second, independent consumer. The only
  gap left for audible barks is real `.ogg` assets, not wiring.

`Config.Features.HandlerDownDefense` and `Config.Features.Recall` were also
previously described in this document as having "zero code" or being
"still not built." Both are implemented and wired
(`server/defense.lua`/`client/defense.lua`,
`server/recall.lua`/`client/recall.lua`) — see their rows in the
[Phase 3 table](#phase-3--combat--agility-all-ship-false) above, and all six
Phase 3/5 radial menu entries this unblocked ("Partner Up", "Recall K9",
"Handler-Down Response", "Fetch", "Toggle K9 Vest", "Deploy Kennel") are
live in `client/radial.lua` today, each gated on its own still-`false` flag.

**What is still genuinely unreachable, and why**: nothing, for the "missing
manifest registration" reason this section used to track. What remains off
is off by `Config.Features` default, documented per-flag in the
[config reference](#configfeatures--full-reference) above, or blocked on a
real disclosed gap (bark/ambient audio has no licensed asset yet;
`PropAttachments`/`FetchMechanic`'s attach bone is still the root-bone
placeholder pending the dev-only sweep) — not on a file failing to load.

## Commands

All three certification commands are restricted in-code to players who pass
the certifier-eligibility check (department member at/above
`certifierGrade`, or boss) — not by an ACE permission, so any qualifying
player can use them, not just server admins.

| Command | Usage | Notes |
|---|---|---|
| `/k9certify` | `/k9certify [server id]` | Grants a certification. See [How certification works](#how-certification-works-day-one). |
| `/k9decertify` | `/k9decertify [server id]` | Revokes a certification from an **online** target. Refuses and points to `/k9decertifyoffline` if the target isn't connected. |
| `/k9decertifyoffline` | `/k9decertifyoffline [citizenid] [job]` | Revokes a certification for a **disconnected** target. Refuses and points to `/k9decertify` if the citizenid resolves to an online player. |

Feature-gated commands (each requires its own flag `true`; the command is
never even registered while its flag is `false`):

| Command | Flag | Notes |
|---|---|---|
| `/k9calmdown` | `FearStressSystem` | Self-only, reduces stress early. |
| `/k9meatbait` | `DistractionSystem` | Usable by any player, not just K9-UI-eligible ones. |
| `/k9whistle` | `DistractionSystem` | Same as above. |
| `/k9deploykennel` | `DeployableKennel` | Places a world kennel near the handler. Same action as the radial menu's "Deploy Kennel". |
| `/k9recall` | `Recall` | The handler's "call the dog off" button — ends whatever bite/takedown/drag their partnered K9 currently holds. Deliberately **never** gated on certification, K9 UI access, or proximity — a decertified handler must still be able to call their dog off mid-engagement. A no-op (with a "nothing to recall" notification) if there's nothing active. |
| `/k9propattach` | `PropAttachments` | Toggles the cosmetic vest/harness prop on the caller's own K9-modeled ped. Same action as the radial menu's "Toggle K9 Vest". |
| `/k9throwfetchball` | `FetchMechanic` | Throws the fetch ball. Gated on `HasK9Access()` (a handler command), not on playing a K9 model. Same action as the radial menu's "Fetch: Throw". |
| `/k9dropfetchball` | `FetchMechanic` | Releases a ball the caller's K9 is currently carrying. Same action as the radial menu's "Fetch: Drop". |
| `/k9recallfetchball` | `FetchMechanic` | The thrower's own early-interrupt for their in-progress fetch cycle, in any state. Not gated on `HasK9Access()` — server-side ownership (only the real thrower's own `source`) is the actual check. Same action as the radial menu's "Fetch: Recall". |

### Admin/audit commands (`Config.Features.AdminAuditCommands`)

`server/admin.lua` — read-only wrappers over `k9_certifications`,
`k9_partnerships`, `k9_search_log`, and `k9_progression`, replacing "an
admin runs raw SQL by hand" with five in-game commands. **None of these
five commands are registered at all unless `Config.Features.AdminAuditCommands`
is `true`** (checked once, at resource start) — the flag being `false`
means the commands don't exist, not merely that they're hidden. Zero
mutation paths exist anywhere in this file: every query is a `SELECT`.

**Corrected 2026-08-25 — this is no longer an ACE-gated surface.** It was,
originally; the project owner directed a change to **police job rank**
instead, on the reasoning that "who may review K9 certification/
partnership/search history" is a question for senior officers in-game, the
same authority model every other gated action in this resource already
uses, not a server-console/ACE trust boundary:

- The caller must hold a `job.name` that is a key in `Config.Departments`,
  and either be that department's boss (`job.isboss == true`) or sit at or
  above that department's own `Config.Departments[job.name].auditGrade`
  (a field separate from `certifierGrade`, so a server owner can set the
  audit bar independently of who can grant/revoke certifications — both
  default to the same value per department on day one). **There is no ACE
  permission to grant for these commands at all any more** —
  `Config.AdminAudit.AcePermission` has been removed from `config.lua`.
  This is a **more permissive** default than the old ACE gate: any
  sufficiently senior officer can already run these the moment the flag is
  on, with no separate staff grant step. These commands expose **who
  searched whom, and when**, so treat `auditGrade` as a privacy boundary,
  not just an admin one.
- All five commands share one per-caller cooldown, `Config.AdminAudit.CommandCooldownMs`
  (default `3000`ms).
- The server console (`source == 0`) is **not** trusted by default
  (`Config.AdminAudit.TrustConsole`, default `false`). In FiveM, `source == 0`
  is not only the real console — it's also an RCON client (authenticated by
  `rcon_password` alone) and **any other resource on the server** calling
  `ExecuteCommand`, since these commands are registered unrestricted.
  Turning `TrustConsole` on accepts all three as trusted equally. A job-rank
  check has no job to compare for the console at all, so without this
  explicit opt-in, console access would be structurally impossible rather
  than a deliberate default. Prefer granting a genuine officer the rank, or
  querying the database yourself, over flipping this on.
- Every invocation — allowed, denied, rate-limited, or malformed — is
  printed to the server console, so the audit surface itself has an audit
  trail.

**`/k9bonetool` (below) is a separate feature.** It used to be ACE-gated;
as of 2026-08-25 it no longer is. It now requires being a department
**boss** specifically (stricter than `auditGrade`'s numeric-rank option
above) **and** a separate server-startup convar an operator must set on
purpose — see its own section below. There is no ACE permission left
anywhere in this resource for either surface.

| Command | Usage | Notes |
|---|---|---|
| `/k9auditcert` | `/k9auditcert [citizenid] [limit]` | Full certification grant/revoke history for one citizenid, across every department, most recently **granted** first. `[limit]` defaults to `Config.AdminAudit.MaxResults.Certifications` (`25`), and is always clamped to `[1, 100]` regardless of config. |
| `/k9auditpartner` | `/k9auditpartner [citizenid] [limit]` | Full partnership history (active and historical) for one citizenid, in **either** the K9 or handler role. Same default/clamp behavior, using `MaxResults.Partnerships`. |
| `/k9auditsearch` | `/k9auditsearch <officer\|plate\|person\|recent> [value] [limit]` | `officer <citizenid>` — searches **performed by** that citizenid; `plate <plate>` — searches **of** that vehicle; `person <citizenid>` — searches **of** that person; `recent` — the N most recent searches of any kind (no `value` argument). All modes order most-recent-first. Same default/clamp behavior, using `MaxResults.SearchLog`. |
| `/k9auditxp` | `/k9auditxp [citizenid]` | Current persisted XP total for one citizenid, from `k9_progression`. A single-row point lookup — no `[limit]`. Reports the raw `xp` integer only, not a derived tier; compare it against `Config.XPTiers` yourself. |
| `/k9auditdept` | `/k9auditdept [job] [limit]` | Current **active** certified-handler roster for one department (a `Config.Departments` key), most recently **granted** first. Active-only, not full history — see `/k9auditcert` above for a per-citizenid history view instead. Same default/clamp behavior, using `MaxResults.Certifications`. |

### Dev-only tooling (`Config.Features.BoneSweepDevTool`)

`/k9bonetool <goto|next|prev|test|stop|known|help> [arg]` —
`server/bonetool.lua` + `client/bonetool.lua`. Exists to answer one open
question: which numeric bone index on a dog skeleton is the correct attach
point for `PropAttachments`'s vest and `FetchMechanic`'s mouth-carry. See
`OPERATOR_RUNBOOK.md` for the full walkthrough.

**Never enable this on a production server. As of 2026-08-25 it is enabled
resource-wide, including on this server if this config file has reached
one.** Check `config.lua` and set this back to `false` (then restart the
resource — see the one-way-door note below) if that's the case here.
`Config.Features.BoneSweepDevTool` spawns and attaches real objects on
command, and must stay `false` outside a dev session.

**Corrected 2026-08-25 — this is no longer an ACE-gated surface.** The
`Config.BoneSweepTool.AcePermission` key (formerly `'k9unit.bonesweep'`)
has been removed from `config.lua` entirely. Reaching this command now
requires **both** of the following at once, neither of which is an ACE
grant:

1. The caller must be a **boss** (`job.isboss == true`) of a job listed in
   `Config.Departments` — a numeric grade is not enough for this
   specific tool, unlike the audit commands above.
2. The server itself must have opted in with a replicated convar,
   `setr qbx_k9unit_enable_bone_dev_tool 1`, set somewhere in its own
   `server.cfg`. Without this convar the command does not exist at all,
   regardless of the feature flag or anyone's rank. This exists precisely
   because this flag was once swept to `true` alongside 39 others with
   nothing to distinguish it — the convar is a second, deliberate opt-in.

There is no ACE permission to grant anywhere in this resource any more.
Treat the feature flag **and** the convar together as the real switch.

**Disabling the flag and restarting are two different things.** Like every
command in this resource, `/k9bonetool` is registered once, at load. Flipping
this flag back to `false` without restarting the resource leaves the
command reachable (to any department boss, if the convar above is still
set) until the next restart — restart after disabling it, don't just flip
the config.

Console (`source == 0`) cannot use this command at all (unlike the audit
commands above) — every subcommand acts on "your own current ped," which
the server console doesn't have.

| Subcommand | Usage | What it does |
|---|---|---|
| `goto` | `/k9bonetool goto <index>` | Preview one exact bone index: a live debug marker plus an on-screen index label, replacing whatever was previously previewed. Clamped to `[0, Config.BoneSweepTool.MaxBoneIndex]` (default `200`). |
| `next` / `prev` | `/k9bonetool next [step]` / `/k9bonetool prev [step]` | Step the current preview index forward/backward by `[step]` (default `1`, must be a positive integer). |
| `test` | `/k9bonetool test` | Really attaches a test prop (`Config.BoneSweepTool.TestPropModel`, default `prop_tennis_ball`) at the current preview index — a real `CreateObject` + `AttachEntityToEntity`, for final visual confirmation. Replaces any previous test object. |
| `known` | `/k9bonetool known` | Resolves a curated list of documented `ePedBoneId` names against your own live ped via `GetPedBoneIndex` and reports every raw result via chat/console — a shortlist of candidates to `goto` and confirm with your own eyes, never a trusted answer by itself. Does not change the current preview index. |
| `stop` | `/k9bonetool stop` | Stops the preview marker and removes any test object. |
| `help` | `/k9bonetool help` | Prints the full subcommand reference. Handled entirely server-side, no client round-trip needed. |

Found the right index? Record it in `config.lua`:
`Config.PropAttachments.boneIndex` (vest) or
`Config.FetchMechanic.mouthBoneIndex` (fetch mouth-carry — also flip
`Config.FetchMechanic.mouthCarryMode` from `'fake'` to `'attach'` once
confirmed).

In-world ox_target equivalents (no command needed; self-targeting is
excluded for certify/revoke):

- **"Certify K9 Handler"** / **"Revoke K9 Certification"** — on any nearby
  player whose live model matches `Config.Peds`.
- **"Attach Leash"** — on any nearby player if either party is K9-modeled.
- **"Load K9 Into Vehicle"** / **"Release K9 From Vehicle"** — on vehicles
  whose model is in `Config.K9Vehicles`, within
  `Config.VehicleInteractMeters`.

## Leash mechanic

Consensual, two-player, never forced on either side:

1. Either party initiates "Attach Leash" (ox_target, or the radial menu's
   auto-targeting item).
2. The **target** gets an accept/decline prompt — nothing activates without
   it.
3. The server determines which side is the K9 (constrained) party via a
   live server-side model check, never a client claim.
4. The handler side must have a `job.name` in `Config.Departments`, but does
   **not** need their own K9 certification.
5. Once attached, the K9-role party's own client softly pulls their
   position back as they approach `Config.LeashMaxDistance` (default `8.0`m)
   from the handler.
6. **Either party can detach at will, with zero consent required** — a
   deliberate "no unbounded trap" guarantee. A hard-cap auto-detach also
   exists (150% of `Config.LeashMaxDistance`, ~12m by default) in case of
   disconnect/teleport/desync.
7. Losing K9 certification while leashed force-detaches the pairing
   immediately.

`Config.LeashMaxDistance` (default `8.0`m) does **three** jobs at once, not
just one: it's the initiate/attach range, the point (75% of it) at which the
elastic pull-back starts, and the base for the hard safety-valve auto-detach
(150% of it). Raising or lowering it moves all three together.

## Vehicle entry/exit — a deliberate exception

K9 vehicle load/release (`client/vehicle.lua`) is **client-only**, with no
server-side event or re-check at all. This is deliberate: the action only
freezes/hides/attaches the acting player's own ped and grants no real
capability — no server-authoritative state depends on "in a K9 vehicle" or
not. A modified client gains nothing here it couldn't already get by
calling the same natives on itself.

## Server-side security model

Every access point that grants a real capability re-verifies on the
**server**, independent of what the client claims about its own job, rank,
proximity, or ped model — job/cert checks, leash formation (re-validated
twice, closing the TOCTOU window), contraband search (re-validated again
after the yielding `ox_inventory` read returns), K9 Inventory/Medkit/
wellbeing interactions (re-derive live model/proximity, consume a real
server-checked item), deployable kennel placement (server computes the spawn
point, never trusts a client-claimed position), and the partnership registry
(re-validated twice, DB-unique-index + mutex backed).

**The one area this resource cannot fully enforce server-side**: for a
**player** target of `BiteAndHold`/`NonLethalTakedown`/`PropDragging`, the
actual restraining effect runs on that player's own client. See the combat
trust-boundary caveat above.

**The one deliberate exception to "always round-trips to the server" at
all** (as opposed to round-tripping but being unable to force compliance) is
vehicle entry/exit — see above.

## Last verified compatible

This resource's assumptions about its five dependencies were checked
against these versions:

| Dependency | Version checked |
|---|---|
| `qbx_core` | 1.24.0 |
| `ox_lib` | 3.39.0 |
| `ox_target` | 1.18.1 |
| `oxmysql` | 2.14.1 |
| `ox_inventory` | 2.47.9 |

**These are the newest versions this resource's assumptions were checked
against, not proven minimums.** Older versions of each dependency may work
fine; they simply haven't been verified. FiveM's `dependencies` block in
`fxmanifest.lua` has **no version-pinning syntax at all** — this was
confirmed against the engine's own source, not assumed. Writing something
like `'ox_inventory@2.47.9'` in that block would not "pin" the version; it
would hard-break resource startup, since `dependencies` only accepts a bare
resource name. This table is documentation for a server owner to manually
cross-check, not an enforcement mechanism `fxmanifest.lua` provides on its
own.

## Where things live

- `fxmanifest.lua`, `config.lua` — manifest and config, at the resource
  root.
- `sql/install.sql` — the one-time DB migration (all four tables above).
- `server/certifications.lua` — grant/revoke (online and offline), the
  in-memory access cache, automatic revocation on job change, and the
  `/k9certify`/`/k9decertify`/`/k9decertifyoffline` commands.
- `server/cooldowns.lua`, `server/entities.lua` — shared cooldown/mutex
  constructors and the defensive netId-to-entity resolver used across this
  resource's other server files. Loaded first in `fxmanifest.lua`.
- `server/main.lua` — the bark relay, the leash consent/state handshake and
  in-memory leash-pair registry, and (Phase 2) the "Scratch to Alert"
  handler.
- `client/main.lua` — the local K9-model self-check, `HasK9Access()`,
  `CanShowK9UI()` (the combinator every other client file gates on), and
  the bark playback receiver.
- `client/movement.lua` — camera toggle, "Sit," the full client side of
  leash, jump/crouch suppression, and (Phase 2) door interaction.
- `client/radial.lua` — the "K9 Unit" radial menu wiring.
- `client/vehicle.lua` — K9 vehicle load/release.
- `client/tracking.lua`, `client/search.lua`, `client/vision.lua`,
  `server/tracking.lua`, `server/search.lua` — Phase 2, disabled by default.
- `client/hud.lua`, `html/index.html`/`style.css`/`app.js` — the vitality
  HUD and its NUI frontend (`HealthStaminaHUD`).
- `locales/en.json` — `ox_lib 'locale'` has been declared in
  `fxmanifest.lua` since Phase 1. **This migration is now complete**
  (corrected 2026-08-25 — an earlier note here said only 3 files were
  migrated; that was true early on and is long stale): every player-facing
  string in this resource goes through `locale()`, across all 47
  `client`/`server` `.lua` files, 311 keys total, cross-checked to zero
  missing and zero unused. See `DEVELOPER_REFERENCE.md` §19 for the pattern, the
  `common.*` shared-key convention, and how to re-verify these numbers
  yourself if time has passed.
- `server/inventory.lua`, `client/inventory.lua` — the K9 gear stash
  (`K9Inventory`).
- `server/medkit.lua`, `client/medkit.lua` — the K9 medkit (`K9Medkit`).
- `server/wellbeing.lua`, `client/wellbeing.lua` — the shared
  Fatigue/Mood/FearStress/Distraction/Injury subsystem.
- `server/progression.lua`, `client/progression.lua` — XP accumulation,
  persistence, and tier application (`XPProgression`).
- `server/kennel.lua`, `client/kennel.lua` — the deployable kennel
  (`DeployableKennel`).
- `server/combat.lua`, `client/combat.lua` — `BiteAndHold`,
  `NonLethalTakedown`, `PropDragging`.
- `server/defense.lua`, `client/defense.lua` — `HandlerDownDefense`.
- `server/partnership.lua`, `client/partnership.lua` — the
  `HandlerPartnership` registry.
- `server/exports.lua`, `client/exports.lua` — the public API documented
  above. Loaded by `fxmanifest.lua` and callable today.
- `client/audio.lua` — the NUI bark/ambient audio bridge. Loaded by
  `fxmanifest.lua`, and now genuinely called from `client/main.lua`'s bark
  relay and from `client/proximityaudio.lua` — see
  [Bark sounds](#bark-sounds-now-ship-with-real-audio) above.
- `client/screenfx.lua` — `ContrabandScreenFX`'s client effect. Loaded by
  `fxmanifest.lua`, and `server/search.lua` now fires the event it listens
  for — wired end-to-end, still ships `false`.
- `server/tenure.lua`, `server/admin.lua` — a tenure-bonus XP feature and
  in-game audit commands, respectively. Both loaded by `fxmanifest.lua`,
  with their own `config.lua` tables and (for tenure) DB column now present.
- `client/propattachment.lua`, `server/propattachment.lua`,
  `client/fetch.lua`, `server/fetch.lua`, `client/proximityaudio.lua`,
  `client/bonetool.lua`, `server/bonetool.lua` — `PropAttachments`,
  `FetchMechanic`, `ProximityAudioFX`, and a dev-only bone-index tool,
  respectively. All seven files are loaded by `fxmanifest.lua` and reachable
  from the radial menu (Toggle K9 Vest, Fetch) or `/k9deploykennel`-style
  commands the moment their flag is `true` — see
  [Known issues](#known-issues--historical-now-resolved) for what used to be
  wrong here.

See `DEVELOPER_REFERENCE.md` (historical design documents §1–§14, each
still marked as such) for the full product spec and phased build plan, and
`CHANGELOG.md` for a running history of what changed and why. See
`OPERATOR_RUNBOOK.md` for the step-by-step guide to standing this resource
up on a real server (install order including the SQL migrations, the
dev-server checks for
`ScentTracking`/`PropAttachments`/`FetchMechanic`/`DeployableKennel`, the
sequenced check for the client-event origin guard, and — now that every
flag is `true` — what to verify given that, plus uninstalling), and
`DEVELOPER_REFERENCE.md` §17 for the open decisions only a server owner can
make, plain-language, including the two (D3, D13) that specifically concern
the combat features this resource now ships enabled.
