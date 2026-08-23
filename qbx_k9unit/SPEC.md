# qbx_k9unit — Product Spec

Status: CORRECTED — Phase 1 build in progress, coordinated directly by the
top-level session (peer-agent-to-peer delegation is not available in this
environment; see §10)
Author: product-agent (spec pass) + top-level session (post-draft
correction), jlwood17190665@gmail.com
Date: 2026-08-23
Target stack: Qbox (qbx_core, ox_lib, ox_target, ox_inventory), oxmysql

> Note on process: this repo was empty at spec time (no existing K9/permission/
> certification code to extend), so this is a greenfield design, not an
> extension of prior art. The original draft (product-agent) could not reach
> feature-ideation-agent, economy-balance-agent, db-schema, or team-leader in
> its session (platform restriction on spawning peer agents from a
> non-top-level session) — see "Consultations I could not get" at the end.
>
> **Post-draft correction:** the original draft assumed a human "handler"
> spawns and remote-controls a separate K9 NPC ped selected from a menu. The
> requester corrected this after the draft landed: the K9 is a player's own
> persistent character (§1). Every section below has been revised for that
> correction; §4.3 (certification schema) has since also been reviewed and
> refined by db-schema and no longer needs that sign-off. Nothing else below
> should be read as having independent specialist sign-off beyond what's
> noted inline.

---

## 1. Goal

> **REVISION NOTE (post-draft correction):** the original draft of this
> section assumed a human "handler" officer spawns and remote-controls a
> separate K9 NPC entity, picked from a menu. That assumption was **wrong**
> and has been corrected throughout this document. See the corrected model
> below and §4.4 for what changed and why.

The K9 is a **player's own persistent character** — someone creates their
character as a dog ped from the start, via the server's existing
character-creation system (entirely outside this resource's scope; this
resource never spawns, despawns, or possesses a ped on anyone's behalf).
That K9-playing player walks to the police department themselves and gets
**hired** into an eligible department through the server's normal, existing
job-hiring flow (also outside this resource's scope — we don't grant jobs).
Once hired, a qualifying high-rank officer **certifies** them using this
resource's certification system (§4), which grants access to K9-specific
mechanics (movement/leash/radial actions/tracking/etc., per whichever
`Config.Features` are enabled) for as long as they hold both the job and an
active certification. **Getting fired from the department automatically
revokes the certification** (§4.4) — access doesn't linger past employment.

Every subsystem stays independently toggleable so a server owner can run
"just the vertical slice" or the full feature set, and access control stays
a real, persistent, server-authoritative permission system rather than a
single hardcoded job/rank check.

**"Handler" in this document now means a partnered human officer** working
alongside the K9 player (for mechanics like leash-together or handler-down
defense — see the flag in §4.4 and §9), never someone who spawns, selects,
or remote-controls the K9. The K9 player controls themselves directly, like
any other player character, at all times.

This spec intentionally covers the *entire* requested feature set (so nothing
gets silently dropped), but explicitly phases it — only Phase 1 is scoped as
an immediately buildable, demoable vertical slice.

---

## 2. Scope

### In scope (this resource, across all phases)
- Qbox-only (qbx_core, ox_lib, ox_target, ox_inventory, oxmysql). No ESX.
- Multi-department, certification-based access control (hard requirement 2).
- Config-driven ped roster, feature toggles, department list, rank thresholds
  (hard requirement 1).
- K9 model detection (recognizing a player's own persistent character as a
  K9), quadruped movement (native, no possession/spawn involved), leash
  mechanics with a partnered handler, radial menu of self-actions, vehicle
  load/unload, bark sounds (Phase 1).
- Scent/blood/water/gunpowder tracking, search zones, contraband alert tiers,
  thermal/night vision (Phase 2).
- Bite-and-hold, non-lethal takedown, handler-down defense mode, prop dragging,
  agility mode (Phase 3).
- ox_inventory K9 stash, XP/progression, vitality HUD (health/stamina/hunger/
  thirst/fatigue/mood/fear-stress/distraction/injury), K9 medkit, contraband
  screen effect (Phase 4).
- Advanced bark radial, proximity audio attenuation, prop attachments, fetch
  mechanic, deployable kennel, K9 camera feed R&D spike (Phase 5).

### Explicit non-goals (this pass)
- **ESX support.** Qbox/QBCore data model only.
- **True live-video PiP camera feed** rendering the dog's actual point of view
  onto a handler's dashcam/bodycam texture in real time. See §7 for why, and
  what the native-only approximation looks like. Only a feasibility spike is
  committed (Phase 5); a working PiP video feed is *not* a committed
  deliverable of this spec.
- **Permanent scar overlay textures** on the K9's skin. Needs a custom ped
  texture/decoration asset pipeline outside plain scripting; out of scope
  entirely unless an artist supplies the asset separately later.
- **Bespoke mocap animation sets** for bite-hold, agility (fence/window
  climbing), and injured-limp gaits. Approximated with existing native anim
  dictionaries/clip sets and task natives (see §7); true custom animations are
  an art-asset request, not something this spec's coders can produce.
- **AI-controlled/automatic patrol K9s.** The K9 is always a real player's
  own persistent character; this resource never spawns, possesses, or
  remote-controls a K9 ped on anyone's behalf, and there is no unmanned
  "ambient K9 NPC" mode.
- **Any concept of "one active K9 per handler," ped selection menus, or
  spawn/despawn.** These were artifacts of the original (incorrect) NPC
  model and do not apply — a K9 player simply plays their own character,
  same as any other job.
- **Integration with any specific third-party bodycam/dashcam resource.**
  Exports/events will be exposed so such integration is *possible*, but no
  particular external resource is assumed to exist on a given server.

---

## 3. Hard requirement 1 — config-driven, in detail

Every feature area maps to one boolean in `Config.Features`. Acceptance for
this requirement is structural, not just "the flag exists":

- [ ] Every leaf feature listed in §6 has a corresponding `Config.Features.X`
      entry, default value documented, and is read at the point where that
      feature would activate (event registration, thread start, menu item
      visibility, or command registration) — not read once at resource start
      and then ignored.
- [ ] Setting any single `Config.Features.X = false` and restarting the
      resource removes that feature's client-visible surface (radial item,
      HUD element, ox_target zone, command) and its server-side handlers stop
      responding to the corresponding events (a manually triggered event for a
      disabled feature must be a no-op server-side, not just hidden
      client-side — this is a security requirement too: a disabled feature
      must not be triggerable by a modified client).
- [ ] `Config.Peds` is a **recognized K9 model list**, not a spawn roster —
      this resource never creates a ped from it. It can have entries
      added/removed/edited (model + label) with zero changes to any `.lua`
      file outside the config — verified by adding a placeholder custom
      model string and confirming both the certify-eligibility check (§4.2)
      and the client-side UI-display check (§4.5) recognize it generically
      (compare against `Config.Peds`, no hardcoded model name anywhere in
      client/server logic).
- [ ] Default `Config.Peds` ships exactly the four native canine models:
      `a_c_shepherd`, `a_c_rottweiler`, `a_c_huskie`, `a_c_chop`.

---

## 4. Hard requirement 2 — multi-department certification access

### 4.1 Design decision

**Access rule:** `player.job.name ∈ Config.Departments` **AND** the player
holds an **active** K9 certification for that job, checked **server-side**
on every access point (menu open request *and* the actual spawn request —
not just once).

**Assumption on rank auto-bypass (stated explicitly, per the ask):** by
default, **no rank auto-bypasses certification**, including the department's
own chief/boss. `autoAccessGrade` exists as an optional per-department config
field for server owners who want a boss-rank bypass, but it defaults to
`nil` (disabled) in the shipped config. Rationale: a single uniform check
("in department AND certified") is easier to reason about and audit than two
divergent paths that behave differently near the boundary; it also means the
person who *can* grant certifications has a trivial one-click way to certify
themselves (`Config.AllowSelfCertification = true`, see below) rather than
needing a permanent structural exception. If this assumption is wrong for how
the target server actually wants to run K9 units, it's a one-line config
change (`autoAccessGrade`), not a code change.

**Self-certification:** `Config.AllowSelfCertification` (default `true`)
lets a certifier-grade+ officer grant/revoke their *own* certification. This
exists to bootstrap a fresh server (someone has to be the first certified
handler) without requiring a second officer online. Settable to `false` if a
server wants to force a second-party grant always.

### 4.2 Certifier eligibility

A player may grant or revoke a K9 certification for a target player if:
1. Granter's `job.name` is a key in `Config.Departments`, AND
2. Granter's `job.grade.level >= Config.Departments[job].certifierGrade`
   **OR** `job.isboss == true` (boss always qualifies regardless of the
   configured numeric threshold), AND
3. Target's `job.name` is a key in `Config.Departments` (any department in
   the list, not necessarily the same one as the granter — e.g. a police
   chief could certify a sheriff's deputy if that's desired; if a server
   wants same-department-only, that's a one-line change in the grant handler,
   flagged as an open question in §9 rather than assumed either way).
4. Granter and target are within **5 meters** of each other at the moment the
   grant/revoke request is processed **server-side** (checked against live
   entity coordinates, not client-supplied "I'm near them" claims) — this
   applies to both the ox_target flow and the slash-command flow, to prevent
   remote/cross-map certifying via a spoofed command.
5. **(New)** Target's *current* ped model — read server-side via
   `GetEntityModel(GetPlayerPed(targetServerId))`, never a client-reported
   value — is a hash of one of the entries in `Config.Peds`. This prevents
   certifying a human-model officer as a "K9 handler," since the
   certification is specifically for someone embodying a K9 character. This
   check applies to grant only, not revoke (revoking a cert should always be
   possible regardless of the target's current model, including via §4.4's
   automatic path).

### 4.3 Certification data model

**Reviewed and refined by db-schema** (see below) — this section is no
longer a pending review item, it reflects the actual shipped schema.

**Decision: dedicated DB table is the source of truth**, not qbx_core player
metadata alone. Rationale:

- Revocation must work **even when the target is offline** (an admin/chief
  should be able to pull a cert from someone who isn't logged in right now).
  Metadata-only requires loading and rewriting another player's JSON blob out
  of band, which qbx_core supports but is more fragile than a keyed UPDATE.
- An audit trail (who granted/revoked, when) is a de facto requirement of any
  permission-granting system with this size of blast radius (bite-and-hold /
  non-lethal takedown access), and is awkward to reconstruct from metadata
  history alone.
- A table trivially supports "list all certified handlers in department X"
  for an admin command/menu without scanning every player's metadata JSON.
- Cost: one migration, one small table, one extra query on player load (cached
  in memory after that) — cheap relative to the benefit above.

A read-only boolean mirror (`metadata.k9certified`) is still written to the
player's qbx_core metadata **purely for client-side HUD display** (e.g.
"K9 Certified" badge) — it is never read by any server-side authorization
check. This distinction must be called out in code comments for
coder-security's review: **the client can see its own cert flag but the
server never trusts it.**

**Schema (final, as shipped in `qbx_k9unit/sql/install.sql`):**

```sql
CREATE TABLE IF NOT EXISTS `k9_certifications` (
  `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `citizenid`      VARCHAR(50)  NOT NULL,
  `job`            VARCHAR(50)  NOT NULL,      -- department job name at grant time
  `granted_by`     VARCHAR(50)  NOT NULL,      -- citizenid of certifying officer
  `granted_at`     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `revoked_by`     VARCHAR(50)  DEFAULT NULL,  -- citizenid, or a sentinel like 'system:job_change' for §4.4 auto-revokes
  `revoked_at`     DATETIME     DEFAULT NULL,
  `active`         TINYINT(1)   NOT NULL DEFAULT 1,
  `active_cert_key` VARCHAR(105) GENERATED ALWAYS AS (
    CASE WHEN `active` = 1 THEN CONCAT(`citizenid`, '::', `job`) ELSE NULL END
  ) VIRTUAL,
  PRIMARY KEY (`id`),
  KEY `idx_citizen_job_active` (`citizenid`, `job`, `active`),
  KEY `idx_job_active` (`job`, `active`),
  UNIQUE KEY `uq_one_active_cert_per_job` (`active_cert_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**Invariant: at most one `active = 1` row per `(citizenid, job)` pair — now
enforced at both layers**, not app-level only as originally drafted:
- App-level: grant pre-checks for an existing active row and no-ops if found
  ("already certified"); revoke sets `active = 0, revoked_by, revoked_at` on
  the existing active row rather than deleting it (preserves the audit row).
- DB-level backstop: the `uq_one_active_cert_per_job` unique index on the
  generated `active_cert_key` column closes the check-then-act race a
  pure app-level check leaves open (two near-simultaneous grant requests
  both passing the pre-check before either INSERT commits). MySQL/MariaDB
  unique indexes treat every `NULL` as distinct, so revoked rows (which
  generate `NULL`) never collide with each other — only two *active* rows
  for the same `(citizenid, job)` would collide. **coder-backend must treat
  a duplicate-key error (MySQL error 1062) on the grant INSERT as the same
  "already certified" no-op**, not as an unhandled error.

**Exact query patterns (from db-schema review):**
- Hot-path check (player load / job change / grant / revoke — not on every
  menu-open, those hit the in-memory cache):
  `SELECT id FROM k9_certifications WHERE citizenid = ? AND job = ? AND active = 1 LIMIT 1;`
- Grant: pre-check as above; if none found,
  `INSERT INTO k9_certifications (citizenid, job, granted_by) VALUES (?, ?, ?);`
  — catch error 1062 and treat as the "already certified" no-op.
- Revoke (manual or automatic, see §4.4):
  `UPDATE k9_certifications SET active = 0, revoked_by = ?, revoked_at = CURRENT_TIMESTAMP WHERE citizenid = ? AND job = ? AND active = 1;`
  — no `LIMIT` needed; the unique constraint guarantees at most one row matches.
- Admin listing: `SELECT citizenid, granted_by, granted_at FROM k9_certifications WHERE job = ? AND active = 1;`

**Server-side cache:** on player load, server queries the active cert row for
the player's *current* job and caches `Certifications[citizenid] = true|false`
in memory, invalidated/updated immediately on grant/revoke events and on job
change.

**Flow summary:**

| Step | Actor | Event/mechanism |
|---|---|---|
| Grant | Certifier via ox_target "Certify K9 Handler" on nearby K9-model player, or `/k9certify [id]` | client → `qbx_k9unit:server:certifyHandler` → eligibility check (§4.2, incl. target-model check) → INSERT row → cache update → notify both |
| Revoke (manual) | Certifier via ox_target "Revoke K9 Certification", or `/k9decertify [id]` (works offline) | client/command → `qbx_k9unit:server:revokeHandler` → eligibility check → UPDATE row → cache update → notify online target if applicable |
| Revoke (automatic) | System, on the K9 leaving/being fired from the department | `QBCore:Server:OnJobUpdate` handler (§4.4) → UPDATE row with `revoked_by = 'system:job_change'` → cache update → notify target if online |
| Check | Any time a K9 feature gates on access | `lib.callback` `qbx_k9unit:server:hasK9Access` → server checks job ∈ Config.Departments AND (cache[citizenid] OR autoAccessGrade bypass) |
| Display only | Client HUD | reads own `metadata.k9certified` mirror — never used for authorization |

**Explicit security note for coder-security:** every one of the mechanisms
above (grant, manual revoke, check) must re-verify on the **server**,
independent of what the requesting client claims about its own job, rank,
proximity, or ped model. The client-side ox_target option visibility and
command availability are UX conveniences only, not access control — a
modified client calling the server event directly with an arbitrary target
id must still be rejected by the server-side checks in §4.2 and §4.3. The
automatic revoke path (§4.4) is server-triggered and has no client-reachable
entry point at all.

### 4.4 Automatic revocation on leaving the department (NEW — required)

A certification is only valid while the holder is actually employed by an
eligible department. **Being fired from (or otherwise leaving) the
department automatically revokes the certification** — access must not
linger past employment, and must not silently come back if they are later
re-hired without being re-certified.

**Mechanism:** a server-side handler on qbx_core's job-change event:

```lua
AddEventHandler('QBCore:Server:OnJobUpdate', function(source, job) ... end)
```

This is the confirmed real hook — `QBCore:Server:OnJobUpdate` is a
non-networked **server** event in qbx_core, fired whenever a player's job
updates, receiving `(source, job)` where `job` is the new PlayerJob object.
qbx_core's compatibility bridge fires it for both legacy-QBCore-style and
Qbox-native job changes, so it covers the normal hire/fire flows a server's
existing PD job system will use.
([Qbox server events docs](https://docs.qbox.re/resources/qbx_core/events/server))

**Handler logic:**
1. Resolve the player's citizenid from `source`.
2. Determine their *previous* job (the cache already tracks which job the
   cached certification was scoped to — use that, rather than trying to
   reconstruct history from the DB).
3. If they held an active cert for that previous job, and the **new**
   `job.name` is not that same department, run the standard revoke UPDATE
   with `revoked_by = 'system:job_change'` (a sentinel, distinguishable from
   a real citizenid in the audit trail) and `revoked_at = CURRENT_TIMESTAMP`.
4. Invalidate/refresh the in-memory cache entry for that citizenid.
5. Notify the player if they're online ("Your K9 certification has been
   revoked — you are no longer employed by <department>").

**Important consequences to implement deliberately, not accidentally:**
- A cert is **job-scoped**. Leaving and later rejoining the same department
  does **not** restore access — the old row is revoked and inactive; a fresh
  grant from a qualifying certifier is required. (This is now a firm
  requirement, not an open assumption as it was in the original draft.)
- A **grade change within the same department** (e.g. promotion/demotion,
  where `job.name` is unchanged) must **not** revoke the certification —
  only actually leaving the department does. Guard on `job.name` changing,
  not on any `OnJobUpdate` firing at all, or every promotion will silently
  strip certifications.
- The automatic path bypasses §4.2's certifier-eligibility and proximity
  checks entirely (there is no granting officer involved) — but it is
  server-triggered only and must not be exposed as a client-callable event.

### 4.5 Recognizing a K9 character

There is **no spawn step** to hang model detection off, so recognition works
as follows:

- **Authoritative (server):** wherever the model actually matters for a
  security decision — currently only the certify-eligibility check in
  §4.2.5 — the server reads it live via
  `GetEntityModel(GetPlayerPed(targetServerId))` and compares against the
  hashes of `Config.Peds` entries. Never trust a client-reported model.
- **Convenience (client):** the client may check its own
  `GetEntityModel(PlayerPedId())` against `Config.Peds` purely to decide
  whether to show K9-specific UI (radial entries, HUD) at all. This is a
  display optimization, never an access check — a modified client showing
  itself the radial menu still gets rejected server-side on any gated action.
- **No new persistent storage is needed** for "is this character a K9": the
  ped model is already part of the player's persistent character via the
  server's existing character-creation/appearance system, so this resource
  reads it rather than duplicating it. If a specific server's appearance
  resource makes the live model unreliable at the moment of the check (e.g.
  during a model swap), that's flagged as an open question in §9 rather than
  worked around speculatively here.

---

## 5. Config schema (concrete shape)

```lua
Config = {}

-- ======================================================================
-- FEATURE TOGGLES — every leaf feature independently switchable.
-- The code must gate on these at the point of activation, not just declare
-- them (see §3 acceptance criteria).
-- ======================================================================
Config.Features = {
    -- Phase 1 (vertical slice)
    LeashMechanics       = true,
    RadialMenu           = true,
    VehicleEntryExit     = true,
    BasicBarkSounds      = true,
    AgilityBasicJump     = true,  -- native jump/crouch only, no fence-vault logic yet

    -- Phase 2 (tracking & vision)
    ScentTracking        = false,
    BloodTracking        = false,
    WaterTrackingDecay   = false,
    GunpowderSniffing    = false,
    SearchZones          = false,
    ContrabandAlerts     = false,
    ThermalVision        = false,
    NightVision          = false,
    DoorInteraction      = false, -- nudge-open / scratch-to-alert

    -- Phase 3 (combat & action)
    BiteAndHold          = false,
    NonLethalTakedown    = false,
    HandlerDownDefense   = false,
    PropDragging         = false,
    AgilityAdvanced      = false, -- fence/window vault approximation

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory          = false,
    XPProgression        = false,
    HealthStaminaHUD     = false,
    FatigueSystem        = false,
    MoodSystem           = false,
    FearStressSystem     = false,
    DistractionSystem    = false,
    InjuryLimping        = false,
    K9Medkit             = false,
    ContrabandScreenFX   = false,

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial   = false,
    ProximityAudioFX     = false,
    PropAttachments      = false,
    FetchMechanic        = false,
    DeployableKennel     = false,
    CameraFeedPiP        = false, -- experimental; native-only approximation, see §7
}

-- ======================================================================
-- PED ROSTER — extensible, no code changes needed to add a streamed model.
-- ======================================================================
Config.Peds = {
    { model = 'a_c_shepherd',   label = 'German Shepherd' },
    { model = 'a_c_rottweiler', label = 'Rottweiler' },
    { model = 'a_c_huskie',     label = 'Husky' },
    { model = 'a_c_chop',       label = 'Chop (K9 Unit)' },
    -- Example custom streamed model (requires the model to exist in a
    -- streamed resource elsewhere on the server; adding this line is the
    -- *only* change needed to make it selectable):
    -- { model = 'a_c_k9_malinois', label = 'Belgian Malinois' },
}

-- ======================================================================
-- DEPARTMENTS — admin-editable list of job names with K9 access, plus the
-- rank threshold required to grant/revoke certifications for that job.
-- ======================================================================
Config.Departments = {
    ['police'] = {
        label           = 'Los Santos Police Department',
        certifierGrade  = 4,    -- job.grade.level required to grant/revoke certs (job.isboss always qualifies too)
        autoAccessGrade = nil,  -- nil = no auto-bypass; set an integer to let that grade+ skip certification (see §4.1 assumption)
    },
    ['sheriff'] = {
        label           = 'Blaine County Sheriff',
        certifierGrade  = 3,
        autoAccessGrade = nil,
    },
    ['bcso'] = {
        label           = 'Blaine County Sheriff (legacy job name)',
        certifierGrade  = 3,
        autoAccessGrade = nil,
    },
}

Config.AllowSelfCertification = true   -- see §4.1
Config.CertifyProximityMeters = 5.0    -- server-enforced max distance for grant/revoke (§4.2.4)

-- ======================================================================
-- VEHICLES — which vehicle models expose the "Load K9" / "Release K9"
-- ox_target option on their trunk/rear door.
-- ======================================================================
Config.K9Vehicles = {
    'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2',
}
Config.VehicleInteractMeters = 3.0

-- ======================================================================
-- LEASH — Phase 1
-- ======================================================================
Config.LeashMaxDistance = 8.0   -- meters before auto-recall-to-heel triggers

-- ======================================================================
-- XP TIERS — Phase 4, placeholder numbers pending economy-balance-agent review
-- ======================================================================
Config.XPTiers = {
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRange = 5.0  },
    { xp = 500,  label = 'Trained K9', speedMultiplier = 1.05, scentRange = 6.5  },
    { xp = 1500, label = 'Veteran K9', speedMultiplier = 1.10, scentRange = 8.0  },
    { xp = 3500, label = 'Elite K9',   speedMultiplier = 1.15, scentRange = 10.0 },
}

-- ======================================================================
-- CONTRABAND ALERT THRESHOLDS — Phase 2, placeholder pending
-- economy-balance-agent review against actual ox_inventory item weights.
-- ======================================================================
Config.ContrabandAlertTiers = {
    { minWeight = 1,   alert = 'whine' },          -- small personal-use amount
    { minWeight = 250, alert = 'aggressive_bark' }, -- large stash
}
```

---

## 6. Acceptance criteria by feature group

Each group is tagged with the phase it ships in. "N/A this phase" groups
still get criteria now so correctness-overseer has something concrete to
check against whenever that phase lands, but they are not blocking Phase 1.

### 6.1 Core Systems & Controls — **Phase 1**

> Corrected for the persistent-player-character model (§1, §4.4, §4.5). The
> K9 player controls themselves at all times; nothing here spawns, selects,
> or possesses a ped. "Handler" below means a partnered human officer, per
> §1 — the exact two-player leash/command semantics are the spec author's
> best-effort interpretation and are flagged in §9 as worth confirming, not
> asserted as certain.

- [ ] A player whose character is a K9 (own model in `Config.Peds`), whose
      job is in `Config.Departments`, and who holds an active certification
      for that job (§4) sees K9-specific UI (radial menu, HUD once Phase 4
      lands); an uncertified K9-model player or a certified player whose job
      isn't in `Config.Departments` does not — enforced server-side on every
      gated action (§4.5), not just hidden client-side.
- [ ] Player can toggle first-person/third-person camera at the dog's eye
      height while playing their K9 character.
- [ ] The K9 player can run, jump, and crouch using the native quadruped
      locomotion the game already applies based on their ped model — no
      custom animation work required for Phase 1 (see §7 for caveats on
      anything beyond basic locomotion).
- [ ] A radial menu (ox_lib `lib.addRadialItem`, grouped under a "K9 Unit"
      submenu) exposes the K9 player's own actions: Bark, Sit (self
      animation), Attach/Detach Leash (with a nearby partnered officer),
      Enter/Exit Vehicle — each item only appears if its owning
      `Config.Features` flag is `true` AND the access check above passes.
- [ ] Leash mode is a **consensual** two-player interaction with a **real
      movement restriction** while active (confirmed by the requester,
      resolving §9 item 3b — no longer an open question):
      - **Attach requires consent.** Either the K9 or a nearby officer
        initiates "Attach Leash" (ox_target) on the other; the *target* of
        that request gets an accept/decline prompt (ox_lib alert/context),
        and the leash only activates on acceptance. Nobody can be leashed
        without agreeing to it first.
      - **While attached, movement is actually restricted**, not just
        monitored: the leashed player cannot move more than
        `Config.LeashMaxDistance` (default 8m) from the handler — enforced
        by continuously clamping/pulling the leashed player's position back
        toward the handler as they approach that limit (a soft elastic
        constraint), not merely a notify-then-auto-detach.
      - **Either party can detach at will, with no consent required to
        detach.** A "Detach Leash" action is available to both the K9 and
        the handler at all times while leashed — consent gates getting
        leashed, never getting free of it. This is a hard requirement: a
        mechanic that could trap a player leashed with no self-service way
        out is not acceptable.
      - Exceeding `Config.LeashMaxDistance` despite the pull-back (e.g. one
        side disconnects, teleports, or desyncs) is a safety-valve
        auto-detach with a notification to both, distinct from the normal
        in-range pull behavior above.
- [ ] The K9 player can enter/exit any vehicle whose model is in
      `Config.K9Vehicles` via an ox_target option on the vehicle within
      `Config.VehicleInteractMeters` (default 3m), self-administered (they
      interact with the vehicle themselves, nobody does it to them); while
      "in," their ped is hidden/frozen and restored on exit.
- [ ] Basic bark sound plays on a radial-triggered "Bark" action.
- [ ] Door interaction (nudge open / scratch-to-alert) and full agility mode
      (fence/window vaulting) are **not** required in Phase 1 — basic jump
      only (`AgilityBasicJump`); advanced agility ships Phase 3.

### 6.2 Combat, Takedowns & Action — **Phase 3**
- [ ] Bite-and-hold: dog latches onto a target ped/player within a
      configurable range and interrupts the target's sprint/weapon-fire
      ability until the handler issues a Recall or a configurable timeout
      elapses. Implementation note: this is approximated via task/animation
      + a control-disable state on the target, not a literal rigid-body limb
      attachment (see §7).
- [ ] Non-lethal takedown: within a configurable range of a fleeing (sprint-
      state) suspect, dog ragdolls/knocks the target down without applying
      lethal damage (health floor above zero enforced server-side).
- [ ] Handler-down defense: if the handler's health drops below a configured
      threshold or they're downed, the K9 automatically enters an aggressive
      state targeting the nearest hostile within a configured radius, with
      no manual radial input required.
- [ ] Prop dragging: dog can grab a downed ped's collar/scruff and drag them
      at reduced speed toward a handler-designated point; releasing ends the
      drag.
- [ ] All of the above are individually toggleable and each has a cooldown
      config value to prevent spam-triggering as a combat exploit — flagged
      for a PvP-balance pass before this phase ships (would want
      economy-balance-agent or an equivalent PvP-balance reviewer's input,
      not reachable this session).

### 6.3 Scent & Advanced Tracking — **Phase 2**
- [ ] Scent tracking: handler can command a "search" that reveals a trail of
      client-side-only markers toward the nearest configured scent source
      (dropped item/stash location) within a configurable max range.
- [ ] Blood trail tracking works identically but keyed to recent
      damage-event locations rather than item drops.
- [ ] Water tracking degrades/breaks the visible trail when the path crosses
      water (checked via `GetWaterHeight`/water-flag natives), requiring the
      handler to re-acquire the scent on the far bank.
- [ ] Gunpowder residue sniffing keys off recent weapon-discharge event
      locations (native weapon-fire events already fired by the game) within
      a configurable time window.
- [ ] Search vehicle/person: sniff animation triggers an ox_target zone on
      the vehicle/ped that reveals configured contraband if present.
- [ ] Contraband alert tiers: dog's audio/animation response differs by
      total contraband weight found, using the thresholds in
      `Config.ContrabandAlertTiers` (placeholder values pending
      economy-balance-agent review, see §9).
- [ ] Thermal vision and night vision use native `SetTimecycleModifier`/
      nightvision natives only — no custom shader work (matches the request's
      own constraint).

### 6.4 Vision & Tactical Systems — **Phase 2 (basic) / Phase 5 (PiP spike)**
- [ ] Thermal and night vision (see 6.3) ship Phase 2.
- [ ] K9 camera feed PiP is a Phase 5 **research spike only**: see §7 for
      what is and isn't achievable without custom rendering work. No PiP
      video feed is a committed deliverable of this spec.

### 6.5 Qbox Integration, Inventory & Progression — **Phase 4**
- [ ] Dog has an ox_inventory stash (registered via
      `exports.ox_inventory:RegisterStash`, keyed to the handler's citizenid
      + active K9 slot) sized for a small number of items (armor, treats,
      water bowl), opened via an ox_target option on the dog within a
      configurable range.
- [ ] Job/certification gating from §4 is the *only* gate on who can spawn a
      K9 — this is enforced identically regardless of which phase's features
      are enabled.
- [ ] XP accumulates from configured actions (successful search, successful
      takedown, etc., each a separate configurable XP value) and persists
      per-handler (metadata or a `k9_profiles` table — see §9 open question).
- [ ] Crossing an XP threshold in `Config.XPTiers` applies the tier's
      `speedMultiplier` and `scentRange` to the dog immediately, without a
      resource restart.

### 6.6 Status, Vitality & Vulnerabilities — **Phase 4**
- [ ] NUI HUD displays health, stamina, hunger, and thirst for the active K9,
      visible only while a K9 is spawned and controlled/nearby, and only if
      `Config.Features.HealthStaminaHUD` is true.
- [ ] Fatigue: sustained sprinting decays a stamina-linked value that reduces
      max speed when depleted; recovers over time faster near a water bowl
      item or a deployable kennel (Phase 5) than passively.
- [ ] Mood/happiness meter drops on taking damage, is restored by a
      configured "pet" interaction and by feeding a configured food item;
      sustained low mood applies a minor performance penalty (configurable).
- [ ] Fear/stress meter rises under sustained nearby gunfire (tracked via
      weapon-fire events within a configured radius/time window) and, above
      a configured threshold, imposes a hesitation state (brief refusal of
      aggressive commands) until the handler issues a "calm down" radial
      command or the meter decays naturally.
- [ ] Distraction: dog is configured immune to flashbang stun (ignore the
      relevant explosion/stun event for the K9 entity); a thrown "meat bait"
      item or an "ultrasonic whistle" item triggers a configurable
      distraction state (dog breaks command briefly). Note: no literal
      inaudible-frequency audio simulation is implied or required — this is
      a scripted item-triggered state, not a real acoustic effect.
- [ ] Injury/limping: a tracked "leg health" value, when below a configured
      threshold, blocks sprint and high-jump commands and reduces base move
      speed via `SetPedMoveRateOverride`; see §7 for the animation-fidelity
      caveat (no dedicated native quadruped limp clipset is assumed to
      exist — speed reduction is the primary signal, not a bespoke gait).
- [ ] K9 medkit: a handler or EMS-job player can use a configured item on an
      injured K9 within a configurable range to restore health/leg-health,
      gated the same way as human medkit revives already are on the server.
- [ ] Screen-filter effect on contraband ingestion uses native
      `SetTimecycleModifier` with an existing GTA "drug effect" style
      modifier — no custom shader/asset required (matches the request's own
      constraint).

### 6.7 Audio & Immersion Props — **Phase 5**
- [ ] Radial bark options (aggressive/alert/calm) each play a distinct sound
      asset attached to the K9 entity.
- [ ] Growl/pant volume attenuates by distance to a hiding suspect (a
      suspect entity flagged as "hidden"/crouched-in-bush-adjacent within a
      configured radius) — purely a volume/pitch parameter on an existing
      `PlaySoundFromEntity` call, no new engine feature required.
- [ ] Prop attachments (vest, harness, tracking camera) attach a configured
      prop to a configured bone on the K9 model via `AttachEntityToEntity`.
- [ ] Fetch mechanic: dog can pick up, carry (attached to mouth bone), and
      drop a physics prop (e.g. the existing `prop_tennis_ball` game asset,
      or a designated evidence-bag prop) on a handler command.
- [ ] Deployable kennel: handler can place a world or vehicle-mounted kennel
      object; the K9 heals at an accelerated (configurable) rate while
      resting inside its radius.

### 6.8 Cross-cutting: config-driven & certification (Hard Requirements 1 & 2)
- Covered by §3 and §4 above; correctness-overseer should treat those two
  sections as the authoritative acceptance criteria for the two hard
  requirements, independent of which feature-group phase is being reviewed.

---

## 7. Scope reality check — native-only approximation vs. real asset need

| Requested item | Native-only approximation (what ships without new assets) | What would actually need a custom asset |
|---|---|---|
| K9 camera feed PiP | A full-screen camera *takeover* toggle (handler presses a key, screen switches to the dog's camera, like a spectate mode) using a secondary in-game camera (`CreateCam`/`RenderScriptCams`). This is **not** picture-in-picture — it replaces the main view, it doesn't inset it. | A true inset PiP of *live 3D world video* requires a render-target/texture-capture path FiveM does not expose to plain Lua scripts for a moving in-game camera (DUI/NUI textures render HTML, not the 3D scene; there's no native "camera → runtime texture" hook in stock natives). This needs either an engine-level R&D spike (unclear if feasible at all in stock FiveM) or accepting a fundamentally different, lower-fidelity implementation (e.g. a static "K9 view" toggle instead of a literal PiP window). Phase 5 ships a feasibility spike only, not a committed feature. |
| Thermal / night vision | `SetTimecycleModifier`/nightvision natives — this is genuinely native-only and fully achievable, matches the request's own stated constraint. | Nothing extra needed. |
| Bite-and-hold "locks onto arm/leg" | A task/animation state on the dog plus a control-disable flag on the target (can't sprint/fire while "held"), released on Recall/timeout. | A literal physics-attached bite to a specific limb bone with correct IK would need custom animation work; not attempted here. |
| Agility mode (climb fences/windows) | Native jump task + a scripted "vault" that teleports/arcs the ped over a detected low obstacle when triggered near a tagged prop, similar to how existing parkour scripts approximate climbing for non-human peds. | A real climbing animation blended to arbitrary fence heights would need a custom clip set; not attempted here. |
| Limping/injury gait | Reduced move-speed via `SetPedMoveRateOverride`, no distinct visual gait. | A visually distinct limping quadruped animation needs a custom clip set (no default GTA quadruped limp clip is assumed to exist). |
| Permanent scar overlays | Not attempted at all. | Needs a custom ped texture/decoration asset and a decoration pipeline; fully out of scope this pass. |
| Contraband screen filter | `SetTimecycleModifier` reusing an existing GTA "drug effect" modifier. | Nothing extra needed. |
| Bark sounds | Fully achievable, but needs **bundled audio asset files** (bark .ogg/.wav clips) — GTA does not expose a scriptable "make this canine ped emit an aggressive-bark voice line on command" native the way human ped speech works; ambient dog vocalizations are AI-driven, not manually triggerable per type. This is a small, easy-to-source asset requirement, not a scripting blocker, but it is **not** zero-asset. | Higher-fidelity variation (breed-specific barks, snarls) would need a larger sourced/recorded audio library. |
| Prop attachments (vest/harness/tracking camera) | `AttachEntityToEntity` onto an existing or lightly re-purposed GTA prop if a close-enough one exists. | A purpose-built K9 vest/harness/camera-housing model most likely needs a custom prop; base GTA doesn't ship these specifically for a quadruped bone rig. |
| Deployable kennel | Achievable with an existing GTA prop as a stand-in visual. | A purpose-built kennel model needs a custom prop; unconfirmed whether GTA ships one natively. |

---

## 8. Phased build plan

### Phase 1 — vertical slice (must be genuinely usable end to end)
1. Config framework: `Config.Features`, `Config.Peds`, `Config.Departments`,
   `Config.AllowSelfCertification`, `Config.CertifyProximityMeters`.
2. `k9_certifications` table + migration SQL (done — see §4.3, reviewed and
   refined by db-schema; ships at `qbx_k9unit/sql/install.sql`).
3. Certification grant/revoke/check system (server-authoritative, per §4),
   including ox_target "Certify K9 Handler" / "Revoke K9 Certification"
   options, `/k9certify [id]` / `/k9decertify [id]` commands, and the
   automatic revoke-on-job-change handler (§4.4).
4. K9-model + access detection (§4.5): server-side live model check backing
   the certify-eligibility gate, and the `hasK9Access` callback backing every
   feature gate — no ped selection/spawn UI exists.
5. Native quadruped movement (run/jump/crouch, free from the ped model
   itself) + first/third person eye-level camera toggle, active whenever a
   certified K9-model player is playing their character.
6. Leash mechanics: two-player attach/detach interaction with a nearby
   partnered officer, auto-detach past `Config.LeashMaxDistance`.
7. Radial menu (ox_lib) for the K9 player's own actions: Bark, Sit,
   Attach/Detach Leash, Enter/Exit Vehicle.
8. Vehicle entry/exit into any `Config.K9Vehicles` model, self-administered.
9. Basic bark sound on radial trigger.

**Definition of done for Phase 1:** a certified K9-model player in a
configured department sees and can use the K9 radial menu (leash with a
partner, enter/exit a K9 vehicle, bark) — and a K9-model player who isn't
certified, or whose job isn't in `Config.Departments`, cannot, even if they
try to trigger the server events directly. Getting fired from the
department immediately and automatically ends their access.

### Phase 2 — tracking & basic vision
Scent/blood/water/gunpowder tracking, search vehicle/person zones (ox_target),
contraband alert tiers, door interaction (nudge/scratch), thermal + night
vision.

### Phase 3 — combat & advanced agility
Bite-and-hold, non-lethal takedown, handler-down defense mode, prop dragging,
advanced agility (fence/window vault approximation). Recommend a PvP-balance
review pass before enabling by default on a live server.

### Phase 4 — inventory, progression, vitality
ox_inventory K9 stash, XP/progression tiers, full vitality HUD (health/
stamina/hunger/thirst), fatigue, mood, fear/stress, distraction, injury/
limping, K9 medkit, contraband screen effect.

### Phase 5 — audio/props polish + camera R&D spike
Advanced bark radial variety, proximity audio attenuation, prop attachments,
fetch mechanic, deployable kennel, and the K9 camera feed feasibility spike
(§7) — spike outcome determines whether any PiP work is scheduled at all.

---

## 9. Open questions / assumptions needing sign-off

1. ~~DB table vs. metadata for certification (§4.3).~~ **Resolved** —
   reviewed and refined by db-schema; dedicated table confirmed, with an
   added DB-level uniqueness backstop.
2. **Cross-department certifying (§4.2.3).** Spec currently allows a
   certifier from one allowed department to certify a target in a *different*
   allowed department (e.g. police chief certifies a sheriff's deputy). If
   the intent is same-department-only, that's a one-line change, but it's a
   real behavioral fork — flagging rather than silently picking.
3. ~~Does a cert survive a job change and later return to a department?~~
   **Resolved by explicit correction** — no: leaving the department
   automatically revokes the cert (§4.4); a fresh grant is required to
   return, even if they rejoin the same department later.
3b. ~~Two-player leash/command semantics (§6.1, §8).~~ **Resolved by
   explicit confirmation** — leash attach requires consent from whoever is
   being leashed (an accept/decline prompt, never forced), but once
   attached it's a **real movement restriction** (the leashed player is
   actively clamped/pulled back within `Config.LeashMaxDistance`, not just
   monitored-and-notified), and **either party can detach at will with no
   consent needed to do so** — consent gates getting leashed, never getting
   free of it. "Sit" and other self-actions remain the K9 player's own
   emotes (unaffected by this resolution). See §6.1 for the full corrected
   acceptance criteria.
4. **Contraband alert weight thresholds and XP values (`Config.XPTiers`,
   `Config.ContrabandAlertTiers`).** Placeholder numbers only — needs
   economy-balance-agent review against real ox_inventory item weights and
   server progression pacing before Phase 4 ships. Not reachable this
   session.
5. **PvP-balance review for Phase 3** (bite-hold/takedown cooldowns and
   whether K9 apprehension should interact with any existing restraint/cuff
   system already on the target server) — flagged, not resolved here.
6. **Camera feed PiP feasibility (§7)** — genuinely uncertain whether any
   form of real PiP video is achievable in stock FiveM without new native
   support; Phase 5 spike should produce a definitive yes/no before anyone
   commits further design around it.
7. **Bark/vest/harness/kennel audio and prop assets (§7)** — small asset
   requirements that need someone to source (not necessarily commission)
   royalty-free sound/prop assets; flagging so it isn't assumed to be a
   zero-asset, code-only task.

---

## 10. Consultations I could not get this session

Per the platform restriction noted at task start (peer-agent spawning limited
to the top-level session), I was not able to loop in:
- **feature-ideation-agent** — not needed here since the feature was already
  fully specified by the requester, but noting per process.
- **economy-balance-agent** — should review §9.4 (XP tiers, contraband
  weight thresholds) before Phase 4.
- **db-schema** — should review §4.3 (certification table design) before
  Phase 1 ships.
- **team-leader** — should take this spec and break it into tracked tasks
  per phase, assigning coder-architect (config framework, handler-K9 link
  registry), coder-backend (certification system, DB layer), coder-security
  (server-authoritative review of every access check in §4), coder-frontend/
  coder-ui (radial menu, NUI HUD in Phase 4), as appropriate.
