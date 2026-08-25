# qbx_k9unit — Operator Runbook

This is a step-by-step guide for the person standing this resource up on a
real server — not a design document. For *why* something works the way it
does, or for the full list of every config flag, see `README.md`. For the
open decisions only a server owner can make, see `PROJECT_STATUS.md`; this
runbook turns several of those decisions into concrete steps.

**Read this before anything else below: as of 2026-08-25, 39 of this
resource's 40 feature flags are switched on** (checked directly in
`config.lua`, not assumed). The one exception, `CameraFeedPiP`, has no
implementing code at all and was corrected back to `false` — nothing to do
about that one. Every "before you enable X" instruction in this document
below is now "X is already enabled — do this now, not before you flip a
switch that's already flipped." One flag in particular, `BoneSweepDevTool`,
is dangerous to leave on — see section 4 immediately if you haven't
already turned it back off.

**This file needs no `fxmanifest.lua` entry.** Documentation files are never
loaded by the resource — do not add `OPERATOR_RUNBOOK.md` (or `README.md`)
to any `files{}`/`ui_page`/script list. If you see a future PR add one,
that's a mistake, not something this file is missing.

---

## 1. Install order

### 1a. Fresh install (no existing `qbx_k9unit` database)

Run **`sql/install.sql`** once, against your database, before first start.
That single file creates all four tables this resource uses
(`k9_certifications`, `k9_search_log`, `k9_partnerships`, `k9_progression`)
in their final shape — including the constraints and indexes described
below. You do **not** need anything under `sql/migrations/` for a fresh
install; those files exist solely to bring an *older* database up to the
same final shape `install.sql` already produces in one pass.

### 1b. Upgrading an existing `qbx_k9unit` database

Run, **in this exact order**:

1. `sql/install.sql` — safe to re-run; every `CREATE TABLE` is
   `IF NOT EXISTS`, so this is a no-op for anything you already have and
   only fills in a table you're missing entirely.
2. `sql/migrations/0001_create_k9_partnerships.sql`
3. `sql/migrations/0002_create_k9_progression.sql`
4. `sql/migrations/0003_add_k9_partnerships_tenure_bonus_tier_granted.sql`
5. `sql/migrations/0004_add_k9_certifications_active_cert_key.sql`

Each migration file is individually idempotent (safe to run more than
once, and safe even if a later one has already been applied) — but **run
all four, in numeric order, every time you upgrade**, not just the ones
you think you need. `CREATE TABLE IF NOT EXISTS` in `install.sql` does
**not** retroactively add a column or index to a table that already exists
in some older shape. If your database created `k9_certifications` or
`k9_partnerships` before a later feature added a column/constraint to it,
`install.sql` alone will silently leave that column/constraint missing —
only the numbered migration for that specific change fixes an
already-existing table.

**A fresh install and a fully-migrated upgrade only converge once all four
migrations have actually run.** Migration `0004` is the one that matters
most and is the easiest to skip by accident: it backfills
`k9_certifications.active_cert_key` and the `uq_one_active_cert_per_job`
unique constraint onto a `k9_certifications` table that predates them.
Without it, `server/certifications.lua`'s grant path — a check, then an
insert, with no transaction between them — relies entirely on that unique
constraint throwing a duplicate-key error to catch two near-simultaneous
grant requests for the same handler/department. On a database missing
migration `0004`, that error never fires: two overlapping grant requests
can **both** succeed, leaving two simultaneously-active certifications for
the same citizenid/job with no error, no log line, and nothing that would
ever notice. A fresh install never has this gap (`install.sql` creates the
constraint from day one); only an upgraded database that skipped `0004`
does. Run it.

If migration `0004`'s `ADD UNIQUE KEY` step fails with a duplicate-entry
error, that means your database already accumulated more than one
simultaneously-active certification for the same citizenid/job before the
constraint existed — exactly the condition it exists to prevent going
forward. The migration file's own header gives you the query to find the
conflicting rows and the manual step to resolve them (deactivate all but
one, never delete the audit row) before re-running it.

### 1c. Resource install

1. Drop `qbx_k9unit` into your `resources` folder.
2. Confirm these five are installed and start **before** `qbx_k9unit` in
   `server.cfg` (they're declared in `fxmanifest.lua`'s `dependencies`
   block, so a missing one will refuse to start `qbx_k9unit` outright):
   `qbx_core`, `ox_lib`, `ox_target`, `oxmysql`, `ox_inventory`.
3. Add `ensure qbx_k9unit` after those five.
4. Open `config.lua` and set `Config.Departments`, `Config.Peds`, and
   `Config.K9Vehicles` for your server (see `README.md`'s own
   [Installation](README.md#installation) section for the full list).
5. **Create the item/object dependencies below.** Every one of these backs
   a feature that ships `true` by default, and every one is a bare
   placeholder name in `config.lua` — none of them exist in a fresh
   `ox_inventory`/world install on their own, and a missing one doesn't
   error, it just silently never works (`GetItemCount`-style checks return
   0 forever, which reads to a player as "this feature is broken," not
   "this feature is unconfigured"):
   - **`k9_medkit`** (`Config.K9Medkit.itemName`) — an `ox_inventory` item.
     Needed for `K9Medkit` (Treat K9).
   - **`k9_treat`** (`Config.Wellbeing.Mood.feedItemName`) — an
     `ox_inventory` item. Needed for `MoodSystem`'s "Feed K9" action (Pet
     K9 needs no item).
   - **`k9_meat_bait`** (`Config.Wellbeing.Distraction.meatBaitItemName`)
     and **`k9_ultrasonic_whistle`**
     (`Config.Wellbeing.Distraction.whistleItemName`) — both `ox_inventory`
     items. Needed for `DistractionSystem` (`/k9meatbait`, `/k9whistle`).
   - **A `water_bowl`-modeled world object** (`Config.Wellbeing.Fatigue.restSources`)
     — not an inventory item, an actual placed object/prop your server's
     map or a placement resource puts in the world. Needed for
     `FatigueSystem`'s rest-recovery bonus specifically (fatigue still
     regenerates slowly without one; a K9 just never gets the faster
     near-a-rest-source rate). `'water_bowl'` is itself an unverified guess
     at a real model name — confirm it against your own server's assets, or
     change `restSources` to a model you know exists.

   Add each item to your server's own `ox_inventory` items table (the exact
   step depends on your `ox_inventory` setup — see its own documentation)
   before enabling the corresponding feature in front of real players, not
   after.
6. Certify your first handler (`README.md`'s
   [How certification works, day one](README.md#how-certification-works-day-one)).

Only after all of the above is in place should you start working through
section 5 (recommended first tranche) below.

---

## 2. Dev-server checks — now overdue, since these flags are already on

**Originally written as "do this before flipping the flag." All of these
flags are already `true`.** Do these on a real dev server as soon as you
can — they're no longer optional pre-checks gating a decision, they're
verification steps for something already live. None of them are hard
blockers (each feature degrades safely if you skip the check), but each
closes a real, disclosed unknown, and skipping it for longer just means
running longer on an unverified assumption.

### 2a. `ScentTracking` — confirm the `ox_inventory` hook payload

`ScentTracking` depends on `exports.ox_inventory:registerHook('swapItems',
...)`. The hook name and payload shape were confirmed by reading
`ox_inventory`'s source directly, but never verified against a live
install you actually run. The hook already fails safe: it only registers
if a runtime check confirms `registerHook` exists on your build of
`ox_inventory`, and disables scent tracking cleanly with one clear warning
if it doesn't.

**What to actually do:** `Config.Features.ScentTracking` is already `true`
(confirm that's still the case in your own `config.lua`), so on a dev
server just restart, drop an item as a certified K9 handler, and read the
logged hook payload once. Confirm the field names it prints match what
`server/tracking.lua` expects before trusting this in production. This is
a five-minute check, not a code change.

### 2b. `PropAttachments` / `FetchMechanic` — run the bone-index sweep

Both features ship fully playable today, but at the wrong attach point:
the vest sits at bone index `0` (the root bone — always valid, never
crashes, but visibly wrong), and `FetchMechanic` ships in
`mouthCarryMode = 'fake'` (delete-and-reappear) instead of a real
mouth-carry. Neither is broken or unsafe as shipped — this step is about
polish, not safety, so it's fine to skip it and enable both features as-is
if you don't mind the placeholder look.

**`Config.Features.BoneSweepDevTool` is currently `true` everywhere,
including on any live server this config file has reached — not just on a
dev server.** Read section 4 below before doing anything else in this
subsection; the short version is that this flag must never stay `true`
outside a private dev session, and if it's `true` on a real server right
now, turning it back off is more urgent than finishing the sweep itself.

If you want to fix it, on a **dev server only**:

1. Confirm `Config.Features.BoneSweepDevTool = true` on that dev server
   (it already is, resource-wide, as of this document's last check —
   confirm your dev server's own copy of `config.lua` still has it set)
   and restart.
2. Grant yourself `Config.BoneSweepTool.AcePermission` (default
   `k9unit.bonesweep`) via your server's normal ACE/principal setup in
   `server.cfg` (e.g. `add_ace identifier.<yours> k9unit.bonesweep allow`,
   or via a principal group). This is the only ACE permission left anywhere
   in this resource as of 2026-08-25 — the admin/audit commands (`/k9auditcert`
   and friends) no longer use ACE at all, they check police job rank
   instead, so there is no "admin-audit ACE" to keep this one separate
   from any more; `k9unit.bonesweep` still deliberately stands alone as its
   own principal.
3. Connect and play as a K9-modeled ped.
4. Run `/k9bonetool help` for the full workflow, then `/k9bonetool known`
   for a candidate shortlist, `/k9bonetool goto <index>` /
   `next`/`prev` to sweep and preview, and `/k9bonetool test` to confirm
   with a real attached object. `/k9bonetool stop` cleans up when you're
   done.
5. Record the index you found in `config.lua`:
   `Config.PropAttachments.boneIndex` for the vest, or
   `Config.FetchMechanic.mouthBoneIndex` **and** flip
   `Config.FetchMechanic.mouthCarryMode` from `'fake'` to `'attach'` for
   fetch.
6. **Turn `Config.Features.BoneSweepDevTool` back to `false` and restart
   the resource** before this server goes anywhere near production — see
   the one-way-door note in section 4.

### 2c. `DeployableKennel` — eyeball the kennel prop model

`Config.DeployableKennel.propModel` is `'prop_dog_cage_01'` (hash
`379820688`). This replaced an earlier value, `'prop_doghouse_01'`, which
was refuted this pass: it traced to a single unverified third-party
resource's config and does not appear in a 5,171-entry live object
database that has a rendered screenshot for every real entry (its
screenshot URL 404s). `prop_dog_cage_01` **does** appear in that database
with a real screenshot — checkable evidence, not an in-engine
confirmation. Before enabling `DeployableKennel` on a live server, run
`/k9deploykennel` once on a dev server and confirm it actually spawns and
looks reasonable. If it ever fails to load, `Config.DeployableKennel.fallbackPropModel`
(`'prop_tennis_ball'`) takes over automatically — you'll get an obviously-wrong
but real object rather than a silent failure or a broken entity.

---

## 3. The sequenced origin-guard check — run this now, combat is already on

**`BiteAndHold`, `NonLethalTakedown`, and `PropDragging` are already
`true`.** This section used to be framed as a check to run "before
enabling any combat feature." That framing is stale: the decision to
enable them has already been made. What's below is now the check you run
to find out whether that decision is currently safe, not a gate on making
it.

**Background, briefly:** every client-side event handler in this resource
checks `if source ~= 65535 then return end` at the top, to reject a locally
forged event and require a genuine server-originated one. This closed a
real exploit (a player could otherwise loop a local call for indefinite
invincibility, with every feature flag off). The check is applied
resource-wide and is strictly better than nothing — but it has never been
independently confirmed in-engine, and a later review found a specific way
it could plausibly fail **open**: if FiveM's client runtime sets `source`
as an ordinary global that's populated on a genuine network receive and
then simply **never cleared**, any client that has *ever* received one real
server event (which is every client, within seconds of connecting) could be
carrying a stale `source == 65535` that a later, locally-forged call would
inherit and pass through.

**This means the naive test is worthless.** Firing a local `TriggerEvent`
on a client that has never received anything from the server will read
"clean" either way and tell you nothing about which behavior is real.

**The check you actually need to run, on one client, in this exact order:**

1. Connect a test client to your dev server.
2. Let that client **receive at least one genuine server-originated event**
   first. The easiest one is already live by default: trigger a bark
   (`BasicBarkSounds` ships `true`) and let that client receive the
   server's relayed bark event.
3. From **that same client, without reconnecting**, fire a local
   `TriggerEvent(...)` call against one of the guarded event names (a
   temporary debug print of `source, type(source)` at the top of the
   handler you're testing makes this easy to read).
4. Compare: did `source` read `65535` on the genuine event in step 2, and
   does it **still** read `65535` on the locally-forged call in step 3? If
   it does, the guard is not doing its job — a stale value is passing the
   check.

Running steps 2 and 3 out of order (or skipping step 2 and only testing a
fresh client) tells you nothing. This is the whole point of the sequencing
— do not shortcut it.

**Your call**: treat the guard as sufficient as shipped (it's applied
everywhere, and the per-feature flag gating closes the original
"flags-off" exploit independently of whether this specific guard holds),
or run this exact sequenced test on a dev server before trusting
`BiteAndHold`, `NonLethalTakedown`, or `PropDragging` in production — all
three are already enabled by default; this test is what tells you whether
that's currently safe, not a precondition for turning them on. The more of that
Category B combat surface you turn on, the more this result matters —
Category B effects (movement restriction, forced ragdoll, damage
suppression) only work at all if the target's own client executes them,
and this guard is the only thing standing between "a modified client
ignores the effect" (expected, disclosed) and "a modified client can grant
itself the effect on demand" (a live exploit, if the guard doesn't hold).

---

## 4. One-way doors — know before you flip these

### `BoneSweepDevTool` — currently `true`. This is the most urgent item in this whole document.

**As of 2026-08-25, `Config.Features.BoneSweepDevTool` is `true`.** Its own
code comment says, in these words, "never enable this on a production
server." It spawns and attaches real objects in the world on command from
anyone holding the `k9unit.bonesweep` ACE permission. If this server has
real players on it, this needs fixing now, not at the end of your reading
list.

**What to do, in order:**
1. Open `config.lua`, set `Config.Features.BoneSweepDevTool = false`.
2. **Restart the resource.** This is not optional and not implied by
   saving the file.

**Why the restart matters, specifically:** like every other command in
this resource, `/k9bonetool` is registered **once**, at resource start —
gating happens at registration time, not inside the handler, which is what
makes a disabled feature genuinely inert rather than merely hidden. The
consequence: turning `Config.Features.BoneSweepDevTool`
back to `false` **without restarting the resource** does not unregister
`/k9bonetool`. It stays reachable (still ACE-gated) until the next
restart. For most flags in this resource that's harmless. For this one it
isn't — it spawns and attaches real objects on command. If you ever
turn this on for the dev-server check in section 2b, **restart the
resource after turning it back off**, and never leave it `true` on a
server real players connect to.

### Supplying bark/ambient audio means accepting a licence

No audio ships with this resource — every bark (`BasicBarkSounds`,
`AdvancedBarkRadial`) and the ambient `ProximityAudioFX` resolve to a
silent no-op until you supply four short `.ogg` files yourself
(`html/sounds/{bark,bark_alert,bark_aggressive,bark_calm}.ogg`, plus
`growl_ambient.ogg` for proximity audio). This is silent by design, not a
bug — but if you want it audible, **every candidate source found and
directly checked against its own licence page is either CC BY-SA (3.0 or
4.0) or OGA-BY 3.0. None is public domain.** (Wikimedia's own bark files
that an earlier note called "public domain" are CC BY-SA; the OpenGameArt
file an earlier note called "CC0" is actually OGA-BY 3.0 — it just sits in
a collection *named* "CC0 Audio," which is why a quick text search gets it
wrong.) Read `html/sounds/CREDITS.md` before sourcing anything yourself:

- **CC BY-SA** — attribution *plus* share-alike. Share-alike is a copyleft
  term; think about what it means to apply that to audio shipped inside a
  resource you distribute to other server owners, before accepting it.
- **OGA-BY 3.0** — attribution only, lighter obligation, but the file is
  `.wav` and needs converting to `.ogg` first.
- Commissioning/recording your own, or simply accepting silence and
  leaving `AdvancedBarkRadial`/`ProximityAudioFX` off, are the other two
  options.

This is a licensing decision about *your* project. Nobody can make it on
your behalf, and it isn't reversible in the sense that matters — once you
ship an attribution- or share-alike-obligated file inside a resource you
distribute, that obligation travels with every copy of it.

---

## 5. What used to be "recommended first tranche" — now a catch-up checklist

**This section originally recommended enabling flags gradually, starting
with the lowest-risk group and leaving combat for last, if at all.** That
recommendation has been overtaken: 39 of 40 flags, including combat, are
already `true` (see the top of this document; the one exception,
`CameraFeedPiP`, has no code behind it and isn't relevant here). The advice
below is kept,
rewritten as a checklist of what to verify now that everything is live at
once, rather than a rollout plan — the original reasoning for *why* each
item matters is unchanged, only the tense.

**Tracking/search group** (`ScentTracking`, `BloodTracking`,
`GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`) — still the
lowest-risk group in the whole resource (nothing here restrains, damages,
or moves another player's character, and it's the most reviewed part of
this resource). Two things worth doing now that it's live:

- Run the section 2a dev check for `ScentTracking` — it has an extra
  prerequisite (a live `ox_inventory` hook) the others don't, and that
  check has never been run against a real install.
- Replace `Config.SearchContrabandItems`' placeholder item names
  (`'weed_bud'`, `'coke_brick'`, etc.) with your own economy's real
  `ox_inventory` item names if you haven't already — with `SearchZones`
  live, a search against those placeholder names simply won't find
  anything real on your server.

**Combat group** (`BiteAndHold`, `NonLethalTakedown`, `PropDragging`) —
was the highest-risk group, recommended last "if at all." It's on. That
doesn't mean the risk went away: a modified client can still ignore the
restraining half of these mechanics regardless of config, and the two
open questions in `PROJECT_STATUS.md` (D3, D13) are exactly about how much
that should worry you. Run section 3's sequenced check now, and read
`PROJECT_STATUS.md`'s D3/D13 write-ups if you haven't. Everything else in
this resource (tracking, search, vision, inventory, wellbeing,
progression, kennel, fetch, prop attachments, the admin/audit surface)
carries no equivalent trust-boundary caveat and can be evaluated purely on
whether you want the feature, not on whether it's safe to expose.
