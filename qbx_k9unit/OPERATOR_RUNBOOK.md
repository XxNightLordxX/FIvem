# qbx_k9unit — Operator Runbook

This is a step-by-step guide for the person standing this resource up on a
real server — not a design document. For *why* something works the way it
does, or for the full list of every config flag, see `README.md`. For the
open decisions only a server owner can make, see `DECISIONS_NEEDED.md`; this
runbook turns several of those decisions into concrete steps.

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
5. Certify your first handler (`README.md`'s
   [How certification works, day one](README.md#how-certification-works-day-one)).

Only after all of the above is in place should you start working through
section 5 (recommended first tranche) below.

---

## 2. Dev-server checks required before enabling certain features

Do these on a real dev server — not production — before flipping the
listed flag to `true` there. None of them are hard blockers (each feature
degrades safely if you skip the check), but each closes a real,
disclosed unknown.

### 2a. `ScentTracking` — confirm the `ox_inventory` hook payload

`ScentTracking` depends on `exports.ox_inventory:registerHook('swapItems',
...)`. The hook name and payload shape were confirmed by reading
`ox_inventory`'s source directly, but never verified against a live
install you actually run. The hook already fails safe: it only registers
if a runtime check confirms `registerHook` exists on your build of
`ox_inventory`, and disables scent tracking cleanly with one clear warning
if it doesn't.

**What to actually do:** on a dev server, set `Config.Features.ScentTracking
= true`, restart, drop an item as a certified K9 handler, and read the
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

If you want to fix it:

1. On a **dev server only**, set `Config.Features.BoneSweepDevTool = true`
   and restart.
2. Grant yourself `Config.BoneSweepTool.AcePermission` (default
   `k9unit.bonesweep` — deliberately a *different* ACE principal from the
   admin-audit one below) via your server's normal ACE/principal setup in
   `server.cfg` (e.g. `add_ace identifier.<yours> k9unit.bonesweep allow`,
   or via a principal group).
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

## 3. The sequenced origin-guard check (before enabling any combat feature)

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
or run this exact sequenced test on a dev server before enabling
`BiteAndHold`, `NonLethalTakedown`, or `PropDragging`. The more of that
Category B combat surface you turn on, the more this result matters —
Category B effects (movement restriction, forced ragdoll, damage
suppression) only work at all if the target's own client executes them,
and this guard is the only thing standing between "a modified client
ignores the effect" (expected, disclosed) and "a modified client can grant
itself the effect on demand" (a live exploit, if the guard doesn't hold).

---

## 4. One-way doors — know before you flip these

### `BoneSweepDevTool` needs a restart to turn off, not just a config flip

Like every other command in this resource, `/k9bonetool` is registered
**once**, at resource start — gating happens at registration time, not
inside the handler, which is what makes a disabled feature genuinely inert
rather than merely hidden. The consequence: turning `Config.Features.BoneSweepDevTool`
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

## 5. Recommended first tranche to enable and playtest

Forty `Config.Features` flags exist; five ship `true`. **Don't flip
everything at once.** Pick a first tranche, playtest it, and expand from
there.

**Start with the tracking/search group:** `ScentTracking`, `BloodTracking`,
`GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`. This is the
lowest-risk group in the whole resource — every one of these is read-only
with respect to other players (nothing here restrains, damages, or moves
another player's character), there's no player-vs-player state to abuse,
and this group has been reviewed and re-reviewed more than anything else
built on top of it.

Two things to do before or alongside enabling this group:

- Run the section 2a dev check for `ScentTracking` specifically — it's the
  one flag in this group with its own extra prerequisite (the others don't
  depend on the `ox_inventory` hook at all).
- Before enabling `SearchZones`, replace `Config.SearchContrabandItems`'
  placeholder item names (`'weed_bud'`, `'coke_brick'`, etc.) with your own
  economy's real `ox_inventory` item names — they won't match anything on
  a real server otherwise.

**Leave combat (`BiteAndHold`, `NonLethalTakedown`, `PropDragging`) for
last, if at all.** These are the highest-risk group, for the reasons in
section 3 above and `DECISIONS_NEEDED.md`'s D2 — a modified client can
always ignore the restraining half of these mechanics, and no amount of
config-flipping changes that. Everything else in this resource (tracking,
search, vision, inventory, wellbeing, progression, kennel, fetch, prop
attachments, the admin/audit surface) carries no equivalent trust-boundary
caveat and can be evaluated purely on whether you want the feature, not on
whether it's safe to expose.
