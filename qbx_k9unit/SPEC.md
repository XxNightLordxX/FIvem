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
>
> **Phase 2 detailed scoping (this pass, 2026-08-23, product-agent):** §6.3
> and §6.4's acceptance-criteria bullets were high-level placeholders written
> before any Phase 1 code existed. §11 (new, below) replaces them with
> concrete, checkable acceptance criteria, a config schema addition, a
> file/module plan grounded in Phase 1's actual file-boundary conventions,
> an event/callback contract, a reality-check on native-only feasibility for
> each Phase 2 item, and a sub-phase dependency ordering. §6.3/§6.4 are left
> in place as the high-level anchor for reference, but §11 is the
> authoritative detail for implementation and verification. This pass was
> done while Phase 1 was still in its final review gate, per explicit
> direction not to wait — nothing in §11 depends on Phase 1's review outcome,
> but §11.3's file plan does assume Phase 1's files ship essentially as
> reviewed (client/main.lua, client/movement.lua, client/radial.lua,
> client/vehicle.lua, server/main.lua, server/certifications.lua); if Phase 1
> review produces structural changes to those files, re-check §11.3's
> extension points against the final versions before starting Phase 2
> implementation.

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
on every gated action that grants a real capability (radial menu access,
leash grant/detach, certify/revoke) — not cached client-side as a one-time
pass.

**Exception, confirmed after security review:** K9 vehicle entry/exit
(`client/vehicle.lua`) is deliberately **client-only**, with no
server-side re-check. Unlike every other gated action, it grants no real
capability — it only freezes/hides/repositions the acting player's own
ped, and no server-authoritative state (DB row, cache, or any other
gated check) reads whether a player is "in" a K9 vehicle in Phase 1. A
modified client gains nothing here it couldn't already get by calling the
same client-only natives on itself directly, so a server round-trip would
add complexity/latency for no actual security benefit. This should be
revisited if a later phase (e.g. Phase 4's K9 stash) ever conditions
something server-authoritative on vehicle state — see §7.

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
| Revoke (manual, target online) | Certifier via ox_target "Revoke K9 Certification", or `/k9decertify [id]` | client/command → `qbx_k9unit:server:revokeHandler` → eligibility check → UPDATE row → cache update → notify online target |
| Revoke (manual, target offline) | Certifier via `/k9decertifyoffline [citizenid] [job]` — **command-only, no ox_target/net-event equivalent**, since a disconnected target has no client to interact through and no numeric server id to identify them by | command → `RevokeCertificationOffline` (server-only function, no client-reachable event) → eligibility check (no proximity/model check — impossible against a disconnected target) → UPDATE row by citizenid+job → cache/notify update if the citizenid happens to be online after all |
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
  security or role-assignment decision — the certify-eligibility check in
  §4.2.5, and leash role-assignment (§6.1: determining which party in a
  leash pair is the constrained K9 side) — the server reads it live via
  `GetEntityModel(GetPlayerPed(targetServerId))` and compares against the
  hashes of `Config.Peds` entries. Never trust a client-reported model. One
  shared helper (`IsConfiguredK9Model`) backs every such check rather than
  duplicating the comparison logic per call site.
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
  during a model swap), that's flagged as §9 item 8 rather than worked
  around speculatively here.

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

> **Phase 2 config additions (`Config.Tracking`, `Config.WaterTrackingDecay`,
> `Config.SearchContrabandItems`, `Config.SearchZones`,
> `Config.DoorInteraction`, `Config.Vision`) are specified in full in
> §11.2**, kept out of this section so §5 stays a faithful record of what
> Phase 1 actually shipped (per this file's own top-of-file transcription
> convention in `config.lua`) rather than mixing unreviewed Phase 2 additions
> into the Phase 1 block.

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
      Enter/Exit Vehicle. **Implementation note, resolved during review**:
      each item's *registration* is gated on its owning `Config.Features`
      flag (a disabled feature's item is never added to the menu at all),
      but the *access check* (`CanShowK9UI()`) is re-verified independently
      at `onSelect` time for each item rather than hiding/showing the item
      live as access changes — chosen to avoid submenu-visibility polling
      chatter and reliance on unverified `lib.addRadialItem`/
      `removeRadialItem` ordering semantics. Functionally equivalent
      (nothing usable without access, server independently re-verifies
      regardless) but visibly different from a literal "only appears if
      access passes" reading — accepted as the shipped behavior.
- [ ] Leash mode is a **consensual** two-player interaction with a **real
      movement restriction** while active (confirmed by the requester,
      resolving §9 item 3b — no longer an open question):
      - **Attach requires consent.** Either the K9 or a nearby officer
        initiates "Attach Leash" (ox_target) on the other; the *target* of
        that request gets an accept/decline prompt (ox_lib alert/context),
        and the leash only activates on acceptance. Nobody can be leashed
        without agreeing to it first. The non-K9 side ("handler") must also
        satisfy `job.name ∈ Config.Departments` (§9 item 9) — an arbitrary
        non-department player cannot hold the other end of a working K9's
        leash, even with consent. Server determines which side is the K9
        (constrained) party via the live model check (§4.5), never a
        client-asserted role.
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

> **Superseded in detail by §11.5** (this pass, 2026-08-23) — the bullets
> below are kept as the high-level anchor/summary; §11.5 is the concrete,
> checkable version correctness-overseer should verify against.

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

> **Superseded in detail by §11.5** (this pass, 2026-08-23) for the Phase 2
> bullet — see that section for the concrete acceptance criteria and a
> refinement of exactly which natives to use.

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
| Thermal / night vision | `SetTimecycleModifier`/nightvision natives — this is genuinely native-only and fully achievable, matches the request's own stated constraint. **Refined by §11.6:** the concrete recommended natives are `SetNightvision(true)` for night vision and `SetSeethrough(true)` for thermal (GTA's built-in heat-vision effect, already used for the base game's Predator random event / Cayo Perico thermal goggles) — `SetSeethrough` is a better fit than a generic timecycle modifier because it actually highlights peds as heat sources, which is the actual gameplay point of "K9 thermal vision." | Nothing extra needed. |
| Bite-and-hold "locks onto arm/leg" | A task/animation state on the dog plus a control-disable flag on the target (can't sprint/fire while "held"), released on Recall/timeout. | A literal physics-attached bite to a specific limb bone with correct IK would need custom animation work; not attempted here. |
| Agility mode (climb fences/windows) | Native jump task + a scripted "vault" that teleports/arcs the ped over a detected low obstacle when triggered near a tagged prop, similar to how existing parkour scripts approximate climbing for non-human peds. | A real climbing animation blended to arbitrary fence heights would need a custom clip set; not attempted here. |
| Limping/injury gait | Reduced move-speed via `SetPedMoveRateOverride`, no distinct visual gait. | A visually distinct limping quadruped animation needs a custom clip set (no default GTA quadruped limp clip is assumed to exist). |
| Permanent scar overlays | Not attempted at all. | Needs a custom ped texture/decoration asset and a decoration pipeline; fully out of scope this pass. |
| Contraband screen filter | `SetTimecycleModifier` reusing an existing GTA "drug effect" modifier. | Nothing extra needed. |
| Bark sounds | Fully achievable, but needs **bundled audio asset files** (bark .ogg/.wav clips) — GTA does not expose a scriptable "make this canine ped emit an aggressive-bark voice line on command" native the way human ped speech works; ambient dog vocalizations are AI-driven, not manually triggerable per type. This is a small, easy-to-source asset requirement, not a scripting blocker, but it is **not** zero-asset. | Higher-fidelity variation (breed-specific barks, snarls) would need a larger sourced/recorded audio library. |
| Prop attachments (vest/harness/tracking camera) | `AttachEntityToEntity` onto an existing or lightly re-purposed GTA prop if a close-enough one exists. | A purpose-built K9 vest/harness/camera-housing model most likely needs a custom prop; base GTA doesn't ship these specifically for a quadruped bone rig. |
| Deployable kennel | Achievable with an existing GTA prop as a stand-in visual. | A purpose-built kennel model needs a custom prop; unconfirmed whether GTA ships one natively. |
| **Gunpowder/blood tracking data sources (Phase 2)** | **See §11.6** — both are achievable via native game events/polling, but require small amounts of authored client→server relay code; not literally "free" the way the original §6.3 phrasing could be read. | Nothing extra needed beyond that relay code — no custom asset. |
| **Door interaction "nudge-open" (Phase 2)** | **See §11.6** — scratch-to-alert (pure sound cue) is fully native-only; nudge-open needs a real door-lock resource integration since GTA has no generic native lock-state query for arbitrary map doors. | No asset needed, but a genuine external-resource integration dependency, not purely a scripting task in isolation. |

---

## 8. Phased build plan

### Phase 1 — vertical slice (must be genuinely usable end to end)
1. Config framework: `Config.Features`, `Config.Peds`, `Config.Departments`,
   `Config.AllowSelfCertification`, `Config.CertifyProximityMeters`.
2. `k9_certifications` table + migration SQL (done — see §4.3, reviewed and
   refined by db-schema; ships at `qbx_k9unit/sql/install.sql`).
3. Certification grant/revoke/check system (server-authoritative, per §4),
   including ox_target "Certify K9 Handler" / "Revoke K9 Certification"
   options, `/k9certify [id]` / `/k9decertify [id]` commands,
   `/k9decertifyoffline [citizenid] [job]` for a genuinely disconnected
   target (§4.3's flow table — `/k9decertify` alone cannot reach an
   offline player, since it only ever accepts a numeric server id), and the
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
vision. **See §11 for the detailed spec** (acceptance criteria, config
schema additions, file/module plan, event contract, reality-check, and
sub-phase ordering) — ready for coder-architect/coder-backend/coder-frontend
to pick up as soon as Phase 1's review gate closes.

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
8. **Live model reliability across an appearance/model swap (§4.5).** If a
   server's separate appearance/character-customization resource can change
   a player's base ped model mid-session (not just clothing/texture), the
   live `GetEntityModel` check could theoretically read a stale-relative-to-
   intent value in the instant right around such a swap. Not addressed
   speculatively here — flagged for whoever integrates this on a specific
   server to confirm their appearance system's actual behavior, since it
   varies by server and no fix should be guessed without knowing what it's
   guarding against.
9. ~~Does the non-K9 leash partner ("handler") need to be in an allowed
   department too, or can any player hold the other end of the leash?~~
   **Resolved** — yes, the handler side must also satisfy
   `job.name ∈ Config.Departments` (does **not** require its own active K9
   certification, just department membership — the cert is specifically the
   "I am a working K9" credential, not "I am allowed near one"). Rationale:
   "handler" is defined throughout this spec (§1) as a partnered officer:
   letting an arbitrary non-department player hold the other end of a
   working K9's leash doesn't match that framing, and department membership
   is a cheap, already-available check reusing the exact same
   `Config.Departments` list.
10. **(NEW, Phase 2) Real event/native availability for tracking data
    sources (§11.6).** Blood-trail (via `CEventNetworkEntityDamage`) and
    gunpowder-sniff (via polling `IsPedShooting`) both require each client
    to relay a small custom event to the server itself — there is no single
    native that already delivers a global "damage/gunfire happened here"
    feed server-side for free. Scoped as achievable, native-only, low-effort
    relay code (§11.6), not a blocker, but flagged so it isn't assumed to be
    zero-authored-code the way §6.3's original phrasing ("native weapon-fire
    events already fired by the game") could be misread.
11. **(NEW, Phase 2) ox_inventory export names/signatures** for reading real
    inventory contents and item weights (search zones, contraband tiers) and
    for detecting a fresh item drop (scent tracking's source data) are not
    independently verified against a live ox_inventory install this session
    — same caveat pattern as Phase 1's qbx_core export notes in
    `server/certifications.lua`. Whoever implements `server/search.lua` and
    `server/tracking.lua` (§11.3) should confirm the exact exports before
    writing final code.
12. **(NEW, Phase 2) Door interaction's "nudge-open" needs a real door-lock
    resource to integrate with** (no such resource is in this spec's scope).
    GTA has no generic native for arbitrary map-door lock state. Scoped in
    §11.3/§11.6 as client-only and unlocked-doors-only for Phase 2, with a
    small export hook other resources can implement; if the target server's
    door-lock resource can't be confirmed/integrated, "nudge-open" may need
    to ship even more narrowly (or not at all) while "scratch-to-alert"
    (pure sound cue) ships regardless.
13. **(NEW, Phase 2) `Config.SearchContrabandItems` is a placeholder list**,
    same status as `Config.ContrabandAlertTiers` (item 4 above) — needs
    economy-balance-agent/db-schema review against the real ox_inventory
    items table before Phase 2 ships for real, not just as a demo.
14. **(NEW, Phase 2) Whether tracking trail reveal (scent/blood/gunpowder)
    needs any server-side rate-limit/anti-abuse beyond the per-type cooldown
    in `Config.Tracking`** — e.g. should a K9 be blocked from tracking while
    leashed-and-constrained past the leash limit, or during an active
    search-zone cooldown on the same target? Not resolved here; flagged as a
    judgment call for coder-backend during implementation, not a spec
    mandate either way.

---

## 10. Consultations I could not get this session

Per the platform restriction noted at task start (peer-agent spawning limited
to the top-level session), I was not able to loop in:
- **feature-ideation-agent** — not needed here since the feature was already
  fully specified by the requester, but noting per process.
- **economy-balance-agent** — should review §9.4 (XP tiers, contraband
  weight thresholds) and §9.13 (Phase 2 contraband item list) before Phase 4
  / Phase 2 respectively ship for real.
- **db-schema** — should review §4.3 (certification table design) before
  Phase 1 ships. Also worth a look at §11.4's ephemeral (non-persisted)
  tracking event log design (§11.3's `server/tracking.lua`) to confirm
  in-memory-only is the right call there too (mirrors the leash pairing
  precedent in `server/main.lua`, which is also deliberately not persisted).
- **team-leader** — should take this spec and break it into tracked tasks
  per phase, assigning coder-architect (config framework, handler-K9 link
  registry), coder-backend (certification system, DB layer), coder-security
  (server-authoritative review of every access check in §4), coder-frontend/
  coder-ui (radial menu, NUI HUD in Phase 4), as appropriate. For Phase 2
  specifically (§11), the natural split is coder-backend on
  `server/tracking.lua` + `server/search.lua` (event relay, contraband
  read/weight computation — the two genuinely server-authoritative pieces),
  coder-frontend on `client/tracking.lua` + `client/search.lua` (trail
  rendering, ox_target zones, sniff animation), and coder-ui/coder-frontend
  on `client/vision.lua` (thermal/night vision keybinds) — all reviewed by
  coder-security for the same "server never trusts a client claim" standard
  §4.3 already established for certification.

---

## 11. Phase 2 Detailed Spec

> Author: product-agent, 2026-08-23. Written while Phase 1 was still in its
> final review gate (qa-tester / regression-interaction / correctness-overseer
> all running), per explicit direction to scope Phase 2 in parallel rather
> than wait. Grounded in a full read of the actual Phase 1 files as they
> exist right now (`config.lua`, `client/main.lua`, `client/movement.lua`,
> `client/radial.lua`, `client/vehicle.lua`, `server/main.lua`,
> `server/certifications.lua`, `fxmanifest.lua`) — file boundaries and
> naming conventions below deliberately continue those files' own
> documented patterns rather than inventing new ones. If Phase 1's review
> gate produces structural changes to those files, re-check the extension
> points named below (especially §11.3's "extends" column) against the
> final versions before starting implementation.

### 11.1 Sub-phase ordering (dependency graph)

Phase 2's nine `Config.Features` flags are not all independent. Recommended
build/land order, grouped into sub-phases so coder-architect/team-leader can
parallelize what's genuinely independent and sequence what isn't:

| Sub-phase | Features | Why this order |
|---|---|---|
| **2a — independent, parallelizable, start immediately** | `ThermalVision`, `NightVision`, `DoorInteraction` (scratch-to-alert only) | Pure client-side (vision) or near-pure client-side (door scratch, per §11.3's client-only design) with no dependency on anything else in this phase or on each other. Good first tickets — no shared state to coordinate over. |
| **2b — foundational** | `SearchZones` | Must land before `ContrabandAlerts`: alert tiers are computed *from* a search's weight result (§6.3/§11.5), so there is nothing for tier logic to key off until server-authoritative contraband reading exists. This is also the piece coder-security should review first, per the task's explicit direction to confirm search results can't be client-claimed. |
| **2c — depends on 2b** | `ContrabandAlerts` | Consumes `SearchZones`' weight computation directly (§11.4's `qbx_k9unit:server:searchTarget` response shape includes the computed tier) — do not start this before 2b lands, there is no independent data source for it. |
| **2d — independent of 2b/2c, can run in parallel with them** | `ScentTracking` | Keys off item-drop/stash locations (a different data source than search zones' live-inventory reads), so it has no hard dependency on 2b/2c. Can be built alongside 2b by a second coder. |
| **2e — depends on shared relay infrastructure, land together** | `BloodTracking`, `GunpowderSniffing` | Both need the same new server-side event-relay-and-log infrastructure (`server/tracking.lua`, §11.3) — one client→server relay pattern (damage events / weapon-fire polling) feeding one prune-and-query log. Building them together avoids two divergent copies of that infrastructure. |
| **2f — depends on 2d and/or 2e** | `WaterTrackingDecay` | Not a standalone feature — it's a *modifier* on an existing rendered trail (breaks/fades it at a water crossing). Needs at least one of scent/blood/gunpowder tracking to already be rendering a trail before there's anything to degrade. Land last. |
| **Door interaction, "nudge-open" half** | (still `DoorInteraction`) | Deliberately split from 2a above: nudge-open depends on confirming a door-lock resource integration exists on the target server (§9 item 12, §11.6) — treat as a stretch item within `DoorInteraction`, not a blocker for shipping scratch-to-alert. |

### 11.2 Config schema additions

New top-level `Config.*` tables, in the same style as `config.lua`'s
existing Phase-1 blocks (banner comments, inline rationale). These are
**additions** — none of Phase 1's existing config keys change.

```lua
-- ======================================================================
-- PHASE 2 — TRACKING (scent / blood / gunpowder). Ranges in meters, ages/
-- time windows in seconds. Each trail TYPE is independently gated by its
-- own Config.Features flag (ScentTracking / BloodTracking /
-- GunpowderSniffing) — these tuning tables only take effect for whichever
-- types are enabled; read at the point of use (search command execution),
-- not cached at resource start, per §3's acceptance criteria applied here.
-- ======================================================================
Config.Tracking = {
    Scent = {
        maxRange         = 40.0,  -- max distance from the K9's current position to a valid scent source at search time
        markerSpacing    = 3.0,   -- meters between rendered trail markers/checkpoints
        searchCooldownMs = 5000,  -- per-player cooldown on re-issuing a "search" command of this type
    },
    Blood = {
        maxRange         = 40.0,
        maxAgeSeconds    = 300,   -- damage events older than this are no longer trackable (pruned from the server-side log, §11.4)
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
    },
    Gunpowder = {
        maxRange         = 40.0,
        maxAgeSeconds    = 120,   -- shorter window than blood -- residue is time-sensitive
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
    },
}

-- Water crossing degrades/breaks a visible trail (§6.3, §11.5). Applied by
-- client/tracking.lua while rendering ANY active trail (scent, blood, or
-- gunpowder) -- not a separate trackable type of its own, which is why it
-- has no maxRange/searchCooldownMs of its own above.
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0,  -- how often the rendered path is sampled for water while drawing it. Use GetWaterHeightNoWaves (0x8EE6B53CE13A9794), NOT plain GetWaterHeight -- confirmed by two independent native-verification passes that the wave-motion jitter in plain GetWaterHeight can cause inconsistent water/no-water reads between adjacent samples on calm shorelines; NoWaves gives a frame-stable read appropriate for a fixed-step poll like this.
    breaksTrail          = true, -- true: water fully breaks the trail, handler must re-search on the far bank (§6.3's stated behavior); false: only fades marker opacity near/in water instead of a hard break -- a softer alternative flagged here as a one-line config choice, not a spec mandate either way
}

-- ======================================================================
-- PHASE 2 — SEARCH ZONES & CONTRABAND. Item names below must match real
-- ox_inventory item names on the target server -- PLACEHOLDER list, see
-- §9 item 13 (needs economy-balance-agent/db-schema review before this
-- ships for real). Item WEIGHT for tier computation is read live from
-- ox_inventory's own item registry at search time, never duplicated into
-- this config, so there is exactly one source of truth for item weight
-- and it can never drift out of sync with a server's real items.lua.
-- ======================================================================
Config.SearchContrabandItems = {
    'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol', -- placeholder examples only
}

Config.SearchZones = {
    vehicleSearchDistance = 2.0,   -- ox_target zone radius for "Search Vehicle"
    personSearchDistance  = 2.0,   -- ox_target zone radius for "Search Person"
    sniffAnimDurationMs   = 4000,  -- how long the sniff interaction takes before the result is revealed
    searchCooldownMs      = 10000, -- per-(K9, target) cooldown -- prevents repeat-search spam against the same vehicle/person to fish for a different roll or just to harass
}

-- ======================================================================
-- PHASE 2 — DOOR INTERACTION (nudge-open / scratch-to-alert). See §11.6
-- for why "nudge-open" is conditioned on the target server having a
-- separate door-lock resource, and why it's scoped client-only (mirrors
-- the vehicle-entry-exit "no real capability granted" exception in §4.1).
-- ======================================================================
Config.DoorInteraction = {
    interactDistance      = 1.5,  -- max distance to a door entity to show either option
    nudgeRequiresUnlocked = true, -- hard requirement, not a toggle: nudge-open must never function as a lockpick bypass -- see §11.6
    scratchCooldownMs     = 3000, -- per-player cooldown on the scratch-to-alert sound cue, same rationale as Config.Features.BasicBarkSounds' server-side cooldown in server/main.lua
}

-- ======================================================================
-- PHASE 2 — VISION (thermal / night). Both are native-toggle keybinds, no
-- custom shader/asset -- see §11.6 for the exact natives confirmed/refined
-- against SPEC.md §7's original claim.
-- ======================================================================
Config.Vision = {
    Thermal = { toggleKey = 'K' }, -- drives SetSeethrough(true/false) -- see §11.6
    Night   = { toggleKey = 'J' }, -- drives SetNightvision(true/false) -- see §11.6
}
```

### 11.3 File/module plan

Continuing Phase 1's established boundary logic (thin radial wiring only in
`client/radial.lua`; "own body" self-actions in `client/movement.lua`;
target-entity interactions in their own file per target type, as
`client/vehicle.lua` already does for vehicles; small server-authority-only
actions that aren't part of the permission system itself in
`server/main.lua`, per that file's own trailing comment reserving space for
exactly this: *"Reserved for future Phase 2+ small, access-gated K9 actions
that need server authority but aren't part of the certification/permission
system itself (e.g. a scent-reveal trigger, a contraband-alert trigger)."*):

| File | New or extends | Owns |
|---|---|---|
| `client/tracking.lua` | **New** | Scent/blood/gunpowder self-search: the "Track Scent" / "Track Blood" / "Track Gunpowder" radial items (self-actions, same category as `movement.lua`'s Sit — hence a sibling file rather than folded into `movement.lua`, to keep that file scoped to camera/sit/leash per its own header rather than becoming an everything-file, mirroring the exact reasoning `certifications.lua`'s header already gives for why bark relay lives in `main.lua` instead of there); trail marker rendering (checkpoints/blips) between the K9's live position and the resolved source coords; water-crossing degrade logic (`Config.WaterTrackingDecay`) applied to whichever trail is currently active. Calls the `qbx_k9unit:server:findTrackableSource` callback (§11.4). |
| `client/search.lua` | **New** | Search-vehicle/search-person: registers `exports.ox_target:addGlobalVehicle` and `exports.ox_target:addGlobalPlayer` (and, if the target server exposes peds/NPCs as searchable too, a ped-model variant — flagged as a stretch item, not required for Phase 2's "person" scope which is player-only per §11.5) options that play the sniff animation, then await the `qbx_k9unit:server:searchTarget` callback (§11.4) and play the resulting contraband-alert bark/animation locally based on the returned tier. Kept separate from `client/tracking.lua` because the trust model differs: tracking reveals a client-cosmetic trail (no real capability granted, §11.6), search reveals real, server-verified inventory contents (a real capability, same category as certification) — splitting by trust model, not just by feature name, mirrors how Phase 1 split `certifications.lua` (real permission grants) from `main.lua` (bark/leash, lower-stakes) rather than splitting purely by "which SPEC.md subsection." |
| `client/vision.lua` | **New** | Thermal/night vision toggle keybinds (`RegisterKeyMapping`, mirroring `movement.lua`'s `ToggleK9Camera` pattern exactly — same "cheap, local, free `IsOwnModelK9()` check, not gated behind `CanShowK9UI()`" judgment call `movement.lua`'s header already made for the camera toggle, applied identically here since vision is also a perception QoL toggle, not a granted capability). New file rather than extending `movement.lua` for the same "don't let one file balloon" reasoning as `client/tracking.lua` above — `movement.lua`'s header explicitly scopes it to "camera, Sit, leash," and vision is a big enough sibling concern (two natives, two keybinds, its own on/off state machine) to warrant its own file rather than a fourth unrelated concern bolted onto that one. |
| `client/movement.lua` | **Extends** | Door interaction (`DoorInteraction` flag), both nudge and scratch. Deliberately placed here rather than a new file: it's a small, single self-action-shaped feature (find nearest door within `Config.DoorInteraction.interactDistance`, act on it) — the same shape as the existing Sit action already in this file, not big enough on its own to justify a fifth file. See §11.6 for why nudge-open ships **client-only, with no server event at all** (mirrors `client/vehicle.lua`'s documented exception in §4.1: nudging an already-unlocked door grants no real capability, exactly the same reasoning already applied to vehicle entry/exit) — only scratch-to-alert needs a thin server round-trip (see below), because unlike nudge it produces a shared, audible, broadcast effect other players can hear, the same reason Bark needed one. |
| `server/tracking.lua` | **New** | The event-relay log backing blood-trail and gunpowder-sniff (§11.4): `RegisterNetEvent` handlers that log a damage-event / weapon-fire coordinate (read server-side from the reporting client's own live ped position, never trusting a client-supplied coordinate — same "never trust client claims" standard as §4.3), a periodic prune pass dropping entries older than `Config.Tracking.Blood/Gunpowder.maxAgeSeconds`, and the `qbx_k9unit:server:findTrackableSource` callback that resolves the nearest matching source (scent: queried live from ox_inventory drop data, see §9 item 11; blood/gunpowder: queried from this file's own in-memory log) within `Config.Tracking.<Type>.maxRange` of the K9's live server-side position. New file (not folded into `server/main.lua`) because — unlike bark relay, which is stateless — this owns real per-type state (growing/pruned event logs) large enough to warrant the same "don't let one file balloon" split `certifications.lua` already established relative to `main.lua`. Ephemeral/in-memory only, deliberately not persisted, mirroring `server/main.lua`'s `LeashPairs` precedent (both are live-session data, not account data) — flagged for db-schema to confirm that precedent still holds here (§10). |
| `server/search.lua` | **New** | Search-vehicle/search-person server authority (§11.4): the `qbx_k9unit:server:searchTarget` callback — re-validates `Config.Features.SearchZones`/`HasK9Access(source)`, live server-side proximity to the target vehicle/ped (never client-claimed), reads the target's **real** inventory contents via an ox_inventory server export (exact export TBD, §9 item 11), cross-references `Config.SearchContrabandItems`, computes total weight using ox_inventory's own live item-weight data, looks up the matching tier in the existing `Config.ContrabandAlertTiers`, applies `Config.SearchZones.searchCooldownMs` per (K9, target) pair, and — if `Config.Features.ContrabandAlerts` and a tier matched — triggers a broadcast alert sound/animation the same way `server/main.lua`'s `relayBark` does (reusing that broadcast pattern, not duplicating it — consider exposing a small shared helper from `server/main.lua` if the two end up wanting byte-identical broadcast logic). New file for the same "real capability grant deserves the certification-file's level of scrutiny" reasoning given for `client/search.lua` above. |
| `server/main.lua` | **Extends** | Door scratch-to-alert only: a `qbx_k9unit:server:relayDoorScratch` event, structurally identical to the existing `relayBark` handler immediately above it in that file (same `HasK9Access` re-check, same per-player cooldown-table pattern using `Config.DoorInteraction.scratchCooldownMs`, same broadcast-to-nearby-clients shape) — this is exactly the kind of "small, access-gated K9 action that needs some server authority but isn't part of the certification system" the file's own header already reserves space for. Nudge-open does **not** get an entry here — see the `client/movement.lua` row above for why it's client-only. |
| `client/radial.lua` | **Extends** | Three new self-action items under the existing "K9 Unit" submenu — "Track Scent" / "Track Blood" / "Track Gunpowder" — each gated by its own `Config.Features` flag exactly like the existing Bark/Leash/Vehicle items, each a one-line call into `client/tracking.lua`'s exposed global (`StartScentTrack()` / `StartBloodTrack()` / `StartGunpowderTrack()`), per this file's own header rule ("If an item needs more than a couple of lines to decide what to do, that logic belongs in one of those files, not here"). Vision toggles and door interaction are **not** added to the radial (keybind and ox_target-zone respectively, per the rows above), consistent with the camera toggle's existing precedent of not being a radial item either. |
| `config.lua` | **Extends** | Adds §11.2's five new tables verbatim. |
| `fxmanifest.lua` | **Extends** | Adds `client/tracking.lua`, `client/search.lua`, `client/vision.lua` to `client_scripts` (after the existing four, before nothing — order among Phase 2 files doesn't matter since none of them declare globals another Phase 2 file depends on at load time, unlike Phase 1's `main.lua`-before-`movement.lua` ordering) and `server/tracking.lua`, `server/search.lua` to `server_scripts` (after `server/certifications.lua`, since `server/search.lua` will need `HasK9Access`/`IsConfiguredK9Model` from that file to already be defined as globals at call time — though since Lua resolves globals at call time not load time, strict ordering here is a defensive convention, not a hard requirement, matching how Phase 1's own manifest already orders `server/main.lua` before `server/certifications.lua` despite `main.lua` calling `certifications.lua`'s globals). |

### 11.4 Event/callback contract (Phase 2)

Following the exact documentation convention Phase 1 established (a full
copy of this block belongs in each new file's header comment once
implemented):

**Callbacks (ox_lib `lib.callback`):**
1. `qbx_k9unit:server:findTrackableSource` (trackType: `'scent'|'blood'|'gunpowder'`) → `{ found: boolean, coords: vector3?, breaksAtWater: boolean }` [`server/tracking.lua`]
   Re-validates `Config.Features.<Type>` and `HasK9Access(source)` server-side
   regardless of client UI state. Resolves the caller's own live position via
   `GetEntityCoords(GetPlayerPed(source))` — **never** a client-supplied
   coordinate — and searches for the nearest matching source within
   `Config.Tracking.<Type>.maxRange`. Enforces
   `Config.Tracking.<Type>.searchCooldownMs` per caller. `breaksAtWater` is
   informational only (client still does its own path sampling per
   `Config.WaterTrackingDecay`, this flag just tells it whether the config
   wants a hard break or a soft fade if it finds one).
2. `qbx_k9unit:server:searchTarget` (targetType: `'vehicle'|'person'`, targetNetId: number) → `{ ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }` [`server/search.lua`]
   **This is the security-critical one, per the task's explicit direction.**
   Re-validates `Config.Features.SearchZones`/`HasK9Access(source)`,
   resolves `targetNetId` to a live entity server-side
   (`NetworkGetEntityFromNetworkId`) and confirms it still exists and is
   within `Config.SearchZones.<vehicle|person>SearchDistance` of the
   caller's own live position (never a client-claimed distance). Reads the
   **actual** inventory contents of that vehicle/ped via an ox_inventory
   server export — the client never supplies, and the server never trusts,
   any claim about what contraband is present. Computes `totalWeight` from
   real ox_inventory item-weight data (never `Config.*`-declared weight —
   there is none, deliberately, see §11.2) and looks up `alertTier` from
   `Config.ContrabandAlertTiers`. Enforces
   `Config.SearchZones.searchCooldownMs` per `(source, targetNetId)` pair.
   `reason` is populated (e.g. `'too_far'`, `'on_cooldown'`, `'no_access'`)
   whenever `ok == false`, following the same rejection-reason-string
   convention `server/main.lua`'s `LEASH_REJECT_MESSAGES` already
   established.

**Server events (client→server, `RegisterNetEvent`):**
3. `qbx_k9unit:server:relayDamageEvent` () [`server/tracking.lua`] — triggered
   by a client's own `gameEventTriggered('CEventNetworkEntityDamage', ...)`
   handler when the **local player is the victim** (the one entity every
   client is guaranteed to have streamed in and see its own damage on).
   Takes no meaningful payload — the server logs the reporting client's own
   live coordinates (`GetEntityCoords(GetPlayerPed(source))`), never a
   client-supplied position, exactly like `relayBark`'s existing "resolve
   the sender's own ped, don't trust a claimed netId" pattern.
4. `qbx_k9unit:server:relayWeaponFire` () [`server/tracking.lua`] — triggered
   by a client on a debounced local transition of `IsPedShooting(PlayerPedId())`
   from false to true. Same "server logs the reporting client's own live
   coordinates" rule as event 3. Needs its own tight per-player rate limit
   (a player who fires continuously should not flood this event) —
   independent of, and in addition to, `Config.Tracking.Gunpowder`'s
   *search*-side cooldown, since this is a *logging* cooldown, not a
   *query* cooldown.
5. `qbx_k9unit:server:relayDoorScratch` (doorNetId: number) [`server/main.lua`]
   — structurally identical to `relayBark` (§ existing contract): re-checks
   `Config.Features.DoorInteraction` and `HasK9Access(source)`, applies
   `Config.DoorInteraction.scratchCooldownMs`, then broadcasts a sound-only
   client event. No inventory/lock-state reveal of any kind — purely a
   sound cue, which is exactly why it's allowed to be this simple.

**Client events (server→client, `RegisterNetEvent`):**
6. `qbx_k9unit:client:playDoorScratch` (netId: number) [`client/movement.lua`]
   — mirrors `client/main.lua`'s existing `playBark` handler exactly (resolve
   the network entity, no-op if not streamed in, play a sound).
7. No dedicated client event is needed for tracking-result or search-result
   delivery — both are request/response shaped (§11.4 items 1–2 above), so
   `lib.callback` is the correct fit, consistent with `hasK9Access` already
   being a callback rather than a fire-and-forget event pair in Phase 1.

**Nudge-open has no event or callback at all** — see §11.3/§11.6: it is
scoped as fully client-local (like vehicle entry/exit's documented
exception in §4.1), since a nudge that only ever succeeds against an
already-unlocked door grants no real capability a modified client couldn't
already get by calling the same client-only door-prop natives on itself.

### 11.5 Acceptance criteria by feature (replaces §6.3/§6.4's placeholder bullets)

**Scent tracking** (`Config.Features.ScentTracking`)
- [ ] A certified K9 player (passes `CanShowK9UI()`) can trigger "Track
      Scent" from the K9 Unit radial; a non-qualifying player triggering the
      same server callback directly gets `found = false` and no coordinate
      data, regardless of client-side UI state.
- [ ] The callback resolves the **nearest** configured scent source (a
      dropped/ground-placed item, per §9 item 11's export-TBD note) within
      `Config.Tracking.Scent.maxRange` meters of the K9's own **live
      server-side position** — not a client-reported position.
- [ ] On success, the client renders a sequence of trail markers spaced
      `Config.Tracking.Scent.markerSpacing` meters apart, from the K9's
      current position toward the resolved source coordinate.
- [ ] Re-triggering "Track Scent" before `Config.Tracking.Scent.searchCooldownMs`
      has elapsed since the caller's last search of this type is rejected
      server-side (client-side cooldown display is a convenience, the
      server independently enforces it).
- [ ] With `Config.Features.ScentTracking = false`, the radial item does not
      appear, and the underlying callback returns `found = false`
      unconditionally (a disabled feature is a server-side no-op, not just
      hidden client-side, per §3).

**Blood trail tracking** (`Config.Features.BloodTracking`)
- [ ] Identical trail-rendering/cooldown/disabled-feature behavior to scent
      tracking above, but the source data is the most recent logged
      damage-event location (via `relayDamageEvent`, §11.4 item 3) within
      `Config.Tracking.Blood.maxAgeSeconds`, not an item-drop location.
- [ ] A damage event older than `Config.Tracking.Blood.maxAgeSeconds` is
      never returned as a valid source — verified by triggering a search
      immediately after the window elapses and confirming `found = false`
      (assuming no other, more recent, damage event exists in range).
- [ ] The logged coordinate for a given damage event is the **victim's own
      live server-side position at the moment their client reports it**,
      never a client-claimed coordinate.

**Water tracking / scent degradation** (`Config.Features.WaterTrackingDecay`)
- [ ] While rendering any active trail (scent, blood, or gunpowder), the
      client samples the path every `Config.WaterTrackingDecay.sampleIntervalMeters`
      for water presence (`GetWaterHeight`/water-flag natives).
- [ ] If `Config.WaterTrackingDecay.breaksTrail = true` (default) and a water
      crossing is detected, the trail rendering stops at the water's edge
      and a fresh "Track <Type>" command is required to re-acquire a trail
      on the far bank — the previous trail does not silently resume once
      the player crosses.
- [ ] If `Config.WaterTrackingDecay.breaksTrail = false`, markers within/near
      the detected water instead render at reduced opacity rather than
      being omitted, and the trail continues past the water crossing.
- [ ] With `Config.Features.WaterTrackingDecay = false`, trails render
      through water crossings with no degradation of any kind (Phase 1-style
      simple straight-line rendering), confirming this really is a modifier
      on top of §6.3's other tracking types, not a prerequisite for them.

**Gunpowder residue sniffing** (`Config.Features.GunpowderSniffing`)
- [ ] Identical trail-rendering/cooldown/disabled-feature behavior to scent
      tracking, but the source data is the most recent logged weapon-fire
      location (via `relayWeaponFire`, §11.4 item 4) within
      `Config.Tracking.Gunpowder.maxAgeSeconds`.
- [ ] The logged coordinate is the **shooting player's own live server-side
      position at the moment their client reports the fire event**, never a
      client-claimed coordinate.
- [ ] A weapon fired more than `Config.Tracking.Gunpowder.maxAgeSeconds` ago
      is never returned as a valid source.

**Search vehicle/person + contraband alert tiers** (`Config.Features.SearchZones`, `Config.Features.ContrabandAlerts`)
- [ ] An ox_target "Search Vehicle" option appears on any vehicle within
      `Config.SearchZones.vehicleSearchDistance` while the interacting
      player passes `CanShowK9UI()`; "Search Person" appears identically on
      any player ped within `Config.SearchZones.personSearchDistance`.
- [ ] Selecting either option plays a sniff animation lasting
      `Config.SearchZones.sniffAnimDurationMs`, then awaits the
      `qbx_k9unit:server:searchTarget` callback (§11.4 item 2) for the
      actual result — the animation duration is purely cosmetic pacing, the
      real result is never computed or revealed client-side.
- [ ] **The server, not the client, determines whether contraband is
      found and how much** — reading the target's real ox_inventory
      contents live at request time and cross-referencing
      `Config.SearchContrabandItems`. A modified client claiming
      `contrabandFound = true` in a spoofed response, or calling the
      callback against a target with no actual contraband, gets the real
      (accurate) server-computed result regardless of what it claims —
      verified by confirming the callback's return value is entirely
      server-computed with no client-supplied field echoed back
      unvalidated.
- [ ] If `Config.Features.ContrabandAlerts = true` and the computed
      `totalWeight` meets or exceeds a tier's `minWeight` in
      `Config.ContrabandAlertTiers`, that tier's configured alert (e.g.
      `'whine'` or `'aggressive_bark'`) plays as a broadcast sound/animation
      audible to nearby players, not just the requesting K9 player — mirrors
      how `relayBark` already broadcasts rather than playing client-locally
      only.
- [ ] With `Config.Features.ContrabandAlerts = false`, a successful search
      still reports `contrabandFound`/`totalWeight` to the requesting K9
      player (so "did I find anything" still works), but no alert
      sound/animation broadcast fires — this flag gates the *alert*, not the
      *search* itself (the two features are independently toggleable per
      §3, and `SearchZones` is listed as the dependency in §11.1, not the
      other way around).
- [ ] Re-searching the same target before `Config.SearchZones.searchCooldownMs`
      elapses (per `(K9 player, target)` pair, not globally) is rejected
      server-side with a clear reason, not silently ignored or allowed to
      re-roll.
- [ ] With `Config.Features.SearchZones = false`, neither ox_target option
      appears and the underlying callback rejects with `ok = false` for any
      caller regardless of client state.

**Door interaction** (`Config.Features.DoorInteraction`)
- [ ] "Nudge Open" appears (ox_target or equivalent) on a door entity within
      `Config.DoorInteraction.interactDistance` **only when that door is
      already in an unlocked state** — if `Config.DoorInteraction.nudgeRequiresUnlocked`
      is `true` (the shipped default, and not intended to ever ship as
      `false` — see §11.6), nudge must never open a locked door under any
      circumstance; this is a hard behavioral guarantee, not just a default.
- [ ] Nudge-open is fully client-local: no server event fires for it (§11.3,
      §11.6), consistent with it granting no real capability beyond what a
      player could already achieve by walking through an already-unlocked
      door normally.
- [ ] "Scratch to Alert" is available on any door within
      `Config.DoorInteraction.interactDistance` regardless of lock state,
      triggers `relayDoorScratch` (§11.4 item 5), and is rejected server-side
      if `Config.DoorInteraction.scratchCooldownMs` hasn't elapsed since the
      same player's last scratch — same abuse-prevention shape as
      `BARK_COOLDOWN_MS` already in `server/main.lua`.
- [ ] With `Config.Features.DoorInteraction = false`, neither option appears
      and `relayDoorScratch` is a server-side no-op for any caller.

**Thermal vision** (`Config.Features.ThermalVision`)
- [ ] Pressing `Config.Vision.Thermal.toggleKey` while `CanShowK9UI()`... —
      **open question, resolve before implementation, do not guess**: is
      thermal/night vision gated behind `CanShowK9UI()` (a granted
      capability) or, like the camera toggle, only behind the cheap local
      `IsOwnModelK9()` check (a QoL toggle available to anyone playing a K9
      character)? `movement.lua`'s own header flags this exact question for
      the camera toggle and leans toward "not gated" for QoL toggles — this
      spec's lean, for consistency, is the **same answer as the camera
      toggle** (gate on `IsOwnModelK9()` only, not `CanShowK9UI()`), since
      thermal/night vision is presented in SPEC.md as the K9's own innate
      perception, not a granted departmental privilege — but flagging this
      explicitly rather than asserting it as settled, per this spec's own
      "flag genuine ambiguity" mandate. Whichever answer is chosen, apply it
      identically to both Thermal and Night vision for consistency with each
      other.
- [ ] Toggling on calls `SetSeethrough(true)` (§11.6); toggling off calls
      `SetSeethrough(false)`. No custom shader or asset is used.
- [ ] Thermal vision auto-disables on resource stop (mirrors
      `client/vehicle.lua`'s `onResourceStop` safety-net pattern for its own
      persistent native states) so a `/restart qbx_k9unit` mid-session
      cannot leave a player stuck in the thermal effect with no toggle to
      turn it back off (the new script instance's toggle state resets to
      `false`, but the native effect itself persists across a resource
      restart independent of script state, exactly the same class of bug
      `client/vehicle.lua`'s header already documents and fixes for vehicle
      entry/exit).

**Night vision** (`Config.Features.NightVision`)
- [ ] Identical acceptance criteria to thermal vision above, substituting
      `SetNightvision(true/false)` and `Config.Vision.Night.toggleKey`.
- [ ] Thermal and night vision are mutually exclusive at any given moment
      (toggling one off the other if both were somehow active) — not
      explicitly required by SPEC.md's original wording, but a reasonable
      default given both are full-screen post-effects that would otherwise
      visually conflict; flagged here as a judgment call, not a mandate.

### 11.6 Reality-check refinements

Applying §7's same rigor to every Phase 2 item:

- **Thermal vision — CONFIRMED achievable, refined.** SPEC.md §7 originally
  said "`SetTimecycleModifier`/nightvision natives only." The concrete,
  better-fitting native is `SetSeethrough(true)` — GTA's built-in heat-vision
  effect (the same one used for the base game's "Predator" random event and
  the Cayo Perico heist's thermal goggles item), which actually highlights
  peds as heat sources — closer to the real gameplay intent of "K9 thermal
  vision" than a generic timecycle modifier reskin would be. Fully
  native-only, zero new assets. **Independently re-confirmed** by
  native-api-assistant against the CitizenFX SDK source
  (`Game.cs`'s `Seethrough`/`Nightvision` boolean properties) plus multiple
  real-world FiveM implementations — both natives are genuinely
  toggle-and-forget (no per-frame maintenance thread needed).
- **Night vision — CONFIRMED achievable as stated.** `SetNightvision(true)`
  is the standard native NV-goggle effect. Fully native-only, zero new
  assets, matches SPEC.md §7 exactly. Same independent re-confirmation as
  thermal above.
- **New requirement surfaced during verification, not in the original
  design:** because both natives are global local-render toggles with no
  automatic reset, `client/vision.lua`'s toggle handlers must explicitly
  force both `SetSeethrough(false)`/`SetNightvision(false)` on every exit
  path — player death, disconnect, and §4.4's auto-revoke of certification
  mid-session — since nothing else will turn them off and a player left in
  a stuck thermal/NV view after losing K9 access would be a real bug.
- **Gunpowder sniffing — PARTIALLY OVERSTATED in §6.3's original wording,
  still fully achievable.** "Native weapon-fire events already fired by the
  game" is not quite accurate as a zero-effort claim: there is no single
  native that already delivers a global "a weapon was fired at coordinate X"
  feed to the server for free. The achievable, still fully native/scripting
  path is: each client locally polls (or hooks) its own
  `IsPedShooting(PlayerPedId())` and relays a debounced event to the server
  on a false→true transition (§11.4 item 4) — small, straightforward,
  100%-native-based relay code, but genuinely *authored* relay code, not
  something that already exists for free. Flagged as §9 item 10 so
  implementation doesn't discover this gap partway through.
- **Blood trail — mostly as claimed, same relay caveat.** `gameEventTriggered`
  with the game event name `CEventNetworkEntityDamage` is a real, documented
  FiveM game event carrying victim/attacker/weapon data, so the *detection*
  half of this claim is directly native-supported. However, that event
  fires **locally, per-client**, to whichever clients have the entities
  involved streamed in — it is not automatically visible server-side. The
  victim's own client is the one guaranteed to witness damage to itself, so
  it relays a small event to the server (§11.4 item 3), same "authored relay
  code, still fully native" shape as gunpowder above.
- **Scent tracking (item-drop location) — genuinely uncertain, flagged, not
  guessed.** Whether ox_inventory exposes a server-side hook/export for "an
  item was just dropped in the world at coordinate X" was not verified
  against a live ox_inventory install this session (§9 item 11) — same
  confidence-caveat pattern Phase 1 already used for qbx_core exports in
  `server/certifications.lua`. If no such hook exists, the fallback plan
  (not yet chosen, a decision for whoever implements `server/tracking.lua`)
  is a client-side world-entity proximity scan for ox_inventory's known drop
  prop model/hash — dropped items are real networked world objects either
  way, so this is achievable either through an event hook (if one exists)
  or a scan (if one doesn't), not a hard blocker either way.
- **Search vehicle/person contraband reading — genuinely uncertain export
  names, not a feasibility blocker.** Reading a vehicle trunk's or a
  player's real ox_inventory contents server-side is unambiguously possible
  (ox_inventory is designed exactly for this), but the exact export
  name/signature was not verified against a live install this session (§9
  item 11) — flagged for coder-backend to confirm before writing
  `server/search.lua`'s final code, not asserted as a known quantity here.
- **Door interaction "nudge-open" — a genuine integration dependency, not a
  pure scripting task.** GTA has no generic native to query or set lock
  state on arbitrary map/interior doors the way it does for vehicle doors
  (`SetVehicleDoorsLocked` and friends) — door lock state for MLO/interior
  doors on a typical FiveM server lives entirely inside a separate,
  server-specific door-lock resource's own data model (e.g. `ox_doorlock`,
  a qbx smallresources equivalent, or a fully custom one), with no vanilla
  native surface at all to query it from outside that resource. This is why
  §11.3/§11.5 scope nudge-open strictly to **"only when the door is already
  unlocked"** rather than attempting any lock/unlock logic of its own, and
  why it's client-only with no server round-trip (there is no server-side
  fact to check if the feature never touches lock state) — this makes
  nudge-open safe to ship without an integration decision, at the cost of it
  being a fairly thin feature (a cosmetic push-open animation on doors
  that were already accessible). A richer version that can distinguish
  locked from unlocked doors and only nudge the latter meaningfully would
  need a real integration point (an export hook, per §9 item 12) with
  whatever door-lock resource a given server runs — not attempted
  speculatively here, since guessing at a specific resource's API without
  confirming it exists on the target server would be worse than shipping
  the narrower, safe version.
  **Confirmed correct by native verification**: GTA's native `CDoor` system
  (`DoorSystemGetDoorState`, `DoorSystemFindExistingDoor`, etc.) only covers
  doors R* registered via IPL or a script's own `AddDoorToSystem` call —
  most real door-lock resources (`ox_doorlock` and similar) manage lock
  state as their own data entirely outside `CDoor`. This means nudge-open
  must **never** gate on the native lock-state query at all, even as a
  belt-and-suspenders check: an unregistered door (the common case for a
  door-lock resource's doors) reads as "nothing to say" from `CDoor`, which
  risks being misread as "unlocked" — a false-negative read there would be
  a concrete way to violate the hard `nudgeRequiresUnlocked` guarantee.
  Implementation must stay purely cosmetic (a push animation triggered by
  the K9 walking through a door it can already physically pass), never
  consulting `CDoor` state as a safety check.
- **"Scratch to alert" — CONFIRMED achievable, no caveats.** Pure sound cue,
  identical shape to the already-shipped `relayBark`. No native uncertainty,
  no integration dependency.

### 11.7 Cross-reference

New open questions raised by this section have been appended to §9 (items
10–14) rather than duplicated here, so §9 remains the single running list
correctness-overseer and team-leader can check against.
