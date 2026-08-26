# qbx_k9unit

A K9 unit add-on for Qbox police/security departments: certification,
leash, vehicle loading, tracking, contraband search, combat mechanics,
wellbeing, XP, a supply shop, a leaderboard, training drills, and an
in-game "K9 Command Tablet" for high command to run all of it.

Proprietary, not open source — licensed for use on the purchaser's own
server only. See `LICENSE.md` for the full terms.

**This is the one document for installing, configuring, and running this
resource.** Everything about *playing* it — every command, what each one
needs, and step-by-step walkthroughs for setting up a handler, running a
search, and so on — lives in the K9 Command Tablet's own in-game Help tab
(`/k9tablet`), not here. This document covers what that tablet can't:
getting the resource running in the first place, the decisions you need
to make before real players touch it, and what to do if it misbehaves.

---

## What this needs, before you install it

Install and start these **before** `qbx_k9unit` — `fxmanifest.lua`
enforces this, so FXServer simply refuses to start this resource if any
one of them is missing:

| Resource | Source | Used for |
|---|---|---|
| [`qbx_core`](https://github.com/Qbox-project/qbx_core) | Qbox-project | Player data, jobs, ranks |
| [`ox_lib`](https://github.com/overextended/ox_lib) | overextended | Notifications, callbacks, the radial menu, translations |
| [`ox_target`](https://github.com/overextended/ox_target) | overextended | Every walk-up/look-at interaction (leash, certify, search, shop, etc.) |
| [`oxmysql`](https://github.com/overextended/oxmysql) | overextended | Database access |
| [`ox_inventory`](https://github.com/overextended/ox_inventory) | overextended | Items, stashes, the K9 supply shop, contraband search |

Last checked compatible against: `qbx_core` 1.24.0, `ox_lib` 3.39.0,
`ox_target` 1.18.1, `oxmysql` 2.14.1, `ox_inventory` 2.47.9. Older
versions may still work; they simply haven't been re-checked.

**Database**: MySQL 5.7.8+ or MariaDB 10.2+ (a generated column this
resource uses needs it — an older engine leaves the install half-built).

### About "works with any inventory/dispatch/framework" — read this before you assume it

This resource ships an auto-detection layer that looks at what your
server actually runs and talks to it — inventory, targeting, dispatch,
and the ambulance/downed-player job. Run `/k9compat` in-game (high
command only) to see exactly what it found.

**Inventory and targeting detection genuinely work.** Swap your
inventory or targeting script and this resource adapts — `ox_target`
and `ox_inventory` still have to be installed and started regardless
(they're hard dependencies above), but this resource can route around
them for a specific system if you run something else.

**Framework detection does not mean framework support, and this is the
one place this document is deliberately blunt rather than reassuring:**
`/k9compat` will correctly tell you if you're running QBCore or ESX, but
that is a detection statement, not a compatibility promise. This
resource's entire authorization model — certifications, permissions,
the tablet, XP, combat, effectively everything — reads Qbox's own job/
rank data directly, in well over 150 places in the code — 182, the one
time this was actually counted against the code rather than assumed;
treat that as a measurement taken on one date, not a fixed fact, since
it moves as the code grows. `qbx_core` is a hard dependency and stays
one. If you run QBCore or ESX, detection will identify it correctly and
this resource will still not work on it. There is no config setting
that changes this — it would mean rewriting a large fraction of the
resource, not flipping a switch.

---

## Installing

1. Drop `qbx_k9unit` into your `resources` folder.
2. **Set up the database.** From the resource's `sql/` folder:
   ```bash
   cd qbx_k9unit/sql
   ./k9_setup.sh -d your_database_name -u your_mysql_user
   ```
   This checks your database, **backs up your entire database
   automatically** (not just this resource's tables — nothing runs if
   that backup fails), then installs the tables and runs every pending
   migration, in order. Safe to run on a brand-new database and just as
   safe to run again later on a server you already installed this on.
   Add `--dry-run` to see the plan without changing anything.

   Prefer not to use the script? Run `sql/install.sql` once (every
   `CREATE TABLE` is safe to re-run), then every file in
   `sql/migrations/` in filename order (also safe to re-run). Check
   `sql/migration_status.sql` any time to see what's actually applied.

   **Don't want a database at all?** Set `Config.Database.enabled = false`
   in `config.lua` instead of importing anything. Every feature still
   works tonight, but read "Running with no database" below before you
   choose this for a real server.
3. Add `ensure qbx_k9unit` to `server.cfg`, **after** the five
   dependencies above.
4. Work through "Before real players touch this" below.
5. Certify your first handler: get an eligible job at a high enough
   rank (or department boss), then run `/k9certify [your own server id]`.

`config.lua` is long but ships its own plain-English index at the top
("WHAT IS IN THIS FILE") — search it for the setting you want rather
than reading start to finish. Nearly every one of its 56
`Config.Features` switches ships **on** by default; the exceptions and
what they mean are covered below.

---

## Before real players touch this

Work through all of these first:

- **`Config.Departments`** — your real job names, and per department:
  `certifierGrade` (who can certify a handler), `auditGrade` (the rank
  that can run the read-only audit tools — see "The Audit tab" below,
  reaching this rank alone is deliberately not enough on its own),
  `highCommandGrade` (who bypasses every other rank check and can mint
  XP — set this deliberately, and higher than `auditGrade`).
- **`Config.Peds`** — which ped models count as a K9. Any model works,
  including a non-dog custom streamed one, as long as it's actually
  streamed on your server.
- **`Config.K9Vehicles`** — which vehicles a K9 can ride in. A K9 sits
  in a real seat (rear preferred, never the driver's) — visible to
  everyone else, not hidden or attached to the outside of the car.
- **`Config.TrainingZones`** and **`Config.K9EquipmentShop.locations`**
  — both ship with a single placeholder coordinate near Mission Row PD.
  Move them, or the training yard and the supply shop have nowhere real
  to be used from. (High command can also add/move/remove supply shop
  locations later from the tablet, without touching this file again.)
- **Create these items in your inventory script** — none exist on a
  fresh install, and a missing one doesn't error, it just silently
  never works: `k9_medkit`, `k9_treat`, `k9_meat_bait`,
  `k9_ultrasonic_whistle`, and `k9_tablet` **only if** you set
  `Config.CommandTablet.openMode` to `'item'` or `'both'` (default is
  `'both'`, so you need it either way unless you change that).
- **A `water_bowl`-modeled world object**, if you want the K9 wellbeing
  system's faster near-a-rest-source recovery. This model name is an
  unverified guess — confirm it exists on your server or change it in
  `config.lua`. Nothing breaks if you skip this; recovery is just slower.
- **Decide `Config.K9Appearance.applyPedModelOnCertify`** (default
  `true`). On, certifying someone — or high command assigning them the
  role directly from the tablet — actually changes that player's
  character to a K9 model, recording what they looked like first so
  losing the role changes them back. Off, this resource is a pure
  access-control layer over a character who already chose to look like
  a dog; appearance is never touched.
- **Replace `Config.SearchContrabandItems`' placeholder item names**
  (`weed_bud`, `coke_brick`, etc.) with your own real item names before
  trusting a search result.
- **Set `Config.CommandTablet.branding`** — your server name, logo
  (replace `html/images/logo.png`), and starting theme colors. High
  command can restyle it further, live, from inside the tablet.

### The one flag you should turn back off

**`Config.Features.BoneSweepDevTool` ships `true`.** Its own code
comment says, in these words, never to enable it on a production server
— it spawns and attaches real objects in the world on command. Unless
you are actively lining up a cosmetic attachment point on a private dev
server:

1. Set `Config.Features.BoneSweepDevTool = false` in `config.lua`.
2. Make sure `qbx_k9unit_enable_bone_dev_tool` isn't set to `1`
   anywhere in `server.cfg` — a second, independent switch that also
   has to be on for the tool to be reachable at all.
3. **Restart the resource.** Like every command here, `/k9bonetool` is
   registered once at startup — flipping the flag alone doesn't remove
   it until the next restart.

It's also boss-rank-gated and refuses to run from the server console,
so the practical exposure is narrow — but it's still a dev tool with no
place on a live server.

### `CertificationExpiry` and `CameraFeedPiP` — the two flags whose names need a word of explanation

**`CertificationExpiry` is the one feature that ships off.** Turning it
on is *not* destructive — every certification that already exists keeps
no expiry date, ever, unless a certifier explicitly renews it; only new
grants and renewals get one. It's off because starting a recertification
schedule at all is a policy call worth making on purpose, not something
to inherit by accident.

**`CameraFeedPiP` ships on, but its name overpromises.** A true
picture-in-picture — two live camera views on screen at once — isn't
possible with FiveM today. What's actually built and working: pressing
a key (`H` by default) switches your *entire* screen to your active
partner's viewpoint until you press it again. Needs `HandlerPartnership`
on and an active partnership between the two players.

---

## Running with no database

`Config.Database.enabled = false` is a real, supported mode — every
feature still works, tonight. Read this before choosing it for a server
with real players:

- **What you lose**: certifications, XP, partnerships, permission
  grants, runtime overrides, tablet theming, and K9 appearance are held
  in memory only, for as long as the server keeps running. A crash,
  update, or scheduled restart loses all of it — everyone starts over.
  Nothing corrupts and nothing crashes; it simply never remembers past
  today.
- **What's permanently gone, not just unsaved**: the audit trail. No
  record of who certified whom, no search log, no permission-grant
  history. If a dispute comes up later, there's nothing to check.
- **`oxmysql` is still required, installed and running, regardless.**
  It's a hard dependency checked before `config.lua` is ever read. This
  setting means the resource never *uses* it — it doesn't mean you can
  remove it.
- This is meant for a trial or a quick test, not day-to-day operation.
  If you can run the setup script above, do — your handlers keep what
  they earned.

---

## The command tablet, high command, and things worth knowing before you rely on them

`/k9tablet` (or an item, depending on `Config.CommandTablet.openMode`)
opens the K9 Command Tablet — the in-game control panel for everything
in this resource, and the place to go for a full command reference and
guided walkthroughs (its own Help/Commands tabs cover that; this
section only covers what you need to know *before* you trust it).

It is a **view only** — every action it offers is re-checked
server-side exactly as if the matching chat command had been typed, so
nothing about the tablet itself is a security shortcut.

- **High command** (set per department via `highCommandGrade`, or
  `job.isboss`) gets the full roster and can certify, assign or revert
  the K9 role/appearance for any citizen, grant XP, hand out named
  permissions, block individual people from individual features, add
  or relabel certification tiers and permission keys, retune XP
  thresholds, manage supply shop locations, hand-tune an individual
  K9's speed/scent/medkit-cooldown numbers on top of its rank, flip
  most feature switches and tune numbers live, and restyle the tablet
  itself. A separate "Guided Flows" hub walks high command through the
  common jobs (onboard a handler, offboard one, handle a problem
  player, tune the server) as single sequences instead of scattered
  screens — it fires the exact same underlying actions as the standalone
  screens, nothing new.
- **Every handler and K9** gets a read-only view of their own
  certification, XP, and any personal grants by default
  (`Config.FeatureControl.everyoneCanViewOwnRecord`).

### The Audit tab, and a bootstrap problem that used to strand a solo owner

Some features — `BiteAndHold`, `NonLethalTakedown`, `PropDragging`,
`AdminAuditCommands` (the audit tools), and a few others — need an
individual grant from high command before anyone can use them, even
with their global switch on (`Config.FeatureControl.RequireGrant`).
This is deliberate: nobody has these until high command hands them out,
one person at a time.

That used to create a real problem for the single most common day-one
setup — a server with exactly **one** high-command officer, the owner,
before anyone else is promoted: only high command can grant one of
these, and a self-grant was blocked outright, so that one officer had
no way to ever grant *themselves* access to the Audit tab. **This is
fixed.** `Config.FeatureControl.allowHighCommandSelfGrant` (default
`true`) specifically allows a high-command officer to grant themselves
one of these feature-level permissions — it does not weaken anything
else: self-granting one of the four *named* capabilities
(`k9.access`/`k9.certify`/`k9.audit`/`k9.givexp`) is still blocked
outright with no override, because high command already bypasses those
checks directly and there's no deadlock to fix there. Set
`allowHighCommandSelfGrant = false` only if you specifically want a
second officer's sign-off on every officer's own feature access — and
know that doing so brings the solo-owner deadlock back until a second
high-command officer exists.

### Before you trust the combat features in production

`BiteAndHold`, `NonLethalTakedown`, and `PropDragging` ship on. For a
**player** target, the actual effect (being held, forced down, slowed)
runs on *that player's own game* — a modified client can simply ignore
it. This resource rejects an obviously-forged local trigger, which
closes the most naive version of that exploit, but **this has never
been tested by someone actually trying to break it on a live server.**
That's a decision for you, not something more code review settles — see
"Decisions that need you" below.

Separately: whichever way a player triggers one of these three (the
radial menu, a keybind, or a typed command all exist), it goes through
the exact same server-side check every time. There's no faster or
looser path through a keybind than through the menu.

Combat only ever targets a player your dispatch integration has
flagged **wanted** by default (`Config.Combat.RequireWantedStatus`) —
wire `Config.Combat.WantedStatusCheckOverride` to your own dispatch
resource; the built-in fallback guess is lower-confidence and meant as
a stopgap only.

---

## Known limitations worth knowing plainly

- **This resource is Qbox-only in practice.** See "About works with
  any inventory/dispatch/framework" above.
- **The partnership milestone-bonus anti-farming fix is narrowed, not
  closed.** A K9/handler pair earns a one-time XP bonus at certain
  partnership-length milestones. The fix that stops a pair from
  breaking up and re-partnering to farm that bonus repeatedly lives in
  memory, not the database — a resource restart clears it. In practice
  this means: if your server happens to restart at the exact moment a
  pair breaks up and re-forms, that one pair can re-earn one
  already-earned milestone bonus a second time. It cannot be farmed
  repeatedly, and it takes a restart landing at exactly the wrong
  moment — but it is a real, narrow gap, not a fully closed one.
- **A player can repeatedly frighten someone else's K9** by faking a
  "gunfire nearby" signal, forcing that K9 to refuse Bite & Hold/
  Takedown for about a minute at a time (`FearStressSystem`, on by
  default) — at no cost to the player doing it, and repeatably. This
  has been narrowed (a single episode can't last forever, and resets
  after roughly 64 seconds), but the repeatable part can't be closed in
  code — there is no way to verify who actually fired a gun. It's a
  policy call about the kind of server you want, not a bug.

---

## Decisions that need you, not more code

Three things on this server today are switched on and working as
designed, but genuinely need a decision from you rather than further
development:

1. **Is the combat trust boundary good enough for your server?** Bite &
   Hold, Non-Lethal Takedown, and Dragging are protected from a
   modified game client by a guard that checks where the instruction
   came from. The guard is written and reviewed, but nobody has ever
   actually attacked it on a running server, which is the only way to
   really know it holds — see "Before you trust the combat features in
   production" above. Run that test yourself, accept the risk as-is, or
   turn `BiteAndHold`/`NonLethalTakedown`/`PropDragging` off until it's
   been done.
2. **Is the fear/stress griefing tradeoff acceptable for your
   players?** See the repeatable-frightening limitation just above.
   Leave `FearStressSystem` on for the emergent chaos, turn it off, or
   ask for its cooldowns to be tightened — it can't be made airtight,
   only slower to repeat.
3. **Do you actually need QBCore or ESX support?** Auto-detection
   genuinely works for inventory and targeting. It does not work for
   your core framework: adapters for qb-core/ESX exist in the code, but
   only one file in the whole resource actually uses them — everything
   else (well over 150 places, the exact count depends on how you
   count and shifts as the code grows) calls Qbox directly, and
   `qbx_core` is a hard dependency regardless of what's detected. If
   you run qb-core or ESX, `/k9compat` will correctly identify it and
   this resource will still not work. Say so plainly to your players
   (cheap), or commit to converting those call sites yourself — a large
   project, not a quick fix, and only worth it if you genuinely need it.

---

## Uninstalling / rolling back

Nothing here runs automatically — every step below is run by hand.

**Back up first, always:**
```bash
cd qbx_k9unit/sql/rollback
./backup_k9_tables.sh -d YOUR_DATABASE_NAME -u YOUR_MYSQL_USER
```
This is read-only — it saves every table this resource owns into one
timestamped file and prints the exact command to restore it. Don't
proceed unless you see `BACKUP OK`.

| Your situation | What to do |
|---|---|
| Just want to stop using the resource | Remove `ensure qbx_k9unit` from `server.cfg`. Leave the tables — they cost nothing sitting there. |
| Installing/migrating gave a duplicate-key error | See `sql/migrations/0004_add_k9_certifications_active_cert_key.sql`'s own header for the exact query to find and resolve the conflicting rows. |
| Want to undo one specific migration | Run the matching `sql/rollback/000N_down.sql`. Each one undoes exactly its own migration and is safe to run more than once. |
| Want the tables gone for good | Back up, then run `sql/rollback/uninstall_all.sql` unmodified first — it deletes nothing, only reports what else in your database depends on these tables. To actually delete: open the file, uncomment the confirmation line near the top, and run it again. Prefer `sql/rollback/uninstall.sh`, which backs up automatically and asks you to type your database name back before it does anything. |
| Already broke something and want your data back | Restore the backup the script printed the command for. |

---

## Public API for developers (exports/events)

If you want another one of your resources to react to this one — a
dispatch alert on a K9 going down, a scoreboard reading someone's XP —
this resource exposes a small, deliberately **read-only** API: 9
exports server-side, 19 client-side (each side carries its own
`GetAPIVersion()`), plus fourteen outbound events fired under real
gameplay conditions (certification changes, partnership changes,
search results, XP tier changes, and a few more). No export grants,
revokes, or mints anything; every self-initiated action keeps its own
consent/proximity/cooldown logic that a direct export call would
otherwise bypass. Full signatures, exact payload shapes, and firing
points are in `DEVELOPER_REFERENCE.md` — that's where whoever is
building the integration should look next, not here.

## Other documentation

This file is the one to read for installing, configuring, and
operating this resource. Three other files exist for a different
reader, and none of them are needed to get this resource running:

- **`DEVELOPER_REFERENCE.md`** — for anyone modifying this resource's
  code: full exports/events contracts, internal design, and file-by-
  file behavior.
- **`KNOWN_ISSUES.md`** — bugs and disclosed limitations, for whoever
  maintains the code next.
- **`PROJECT_HISTORY.md`** — what shipped and when.
