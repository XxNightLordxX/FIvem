# qbx_k9unit

A K9 unit add-on for Qbox police/security departments: certification,
leash, vehicle loading, tracking, contraband search, combat mechanics,
wellbeing, XP, a supply shop, a leaderboard, training drills, five
"hunting"/reaction mini-games (see "What's included" below), and an
in-game "K9 Command Tablet" for high command to run all of it.

Proprietary, not open source — licensed for use on the purchaser's own
server only. See `LICENSE.md` for the full terms.

**Readable, not encrypted.** Every line of this resource ships as plain
Lua you can open, read, and debug. It is not escrow-protected. That is a
deliberate choice, and it has a practical consequence worth knowing about
before you buy anything in this category: when an escrow-encrypted script
misbehaves, the error names encrypted code, and neither you nor anyone you
hire can trace it to a line — you wait for the seller. Here, an error names
a real file and a real line number, and if something goes wrong at 2am on a
full server you can at least see what happened. The licence, not
encryption, is what stops redistribution.

**This is the one document for installing, configuring, and running this
resource.** Everything about *playing* it — every command, what each one
needs, and step-by-step walkthroughs for setting up a handler, running a
search, and so on — lives in the K9 Command Tablet's own in-game Help tab
(`/k9tablet`), not here. This document covers what that tablet can't:
getting the resource running in the first place, the decisions you need
to make before real players touch it, and what to do if it misbehaves.

---

## What's included

The full feature set, in brief, so nothing here is a surprise you find
out about from a support ticket. All of these ship **on** by default
unless noted; every one is an independent switch in `Config.Features`
and can be turned off. Full command syntax for all of these is in the
tablet's own Help tab, not here.

- **Certification** — the access-control core: a supervisor certifies a
  department member as a K9 handler, or high command assigns the role
  directly from the tablet. See "How a K9 gets made" below.
- **Leash, vehicle loading, radial menu, basic bark** — the core
  day-to-day handler/K9 interactions.
- **Tracking** (scent/blood/gunpowder trails), **search zones and
  contraband alerts**, **thermal/night vision**, **door interaction**.
- **Combat**: Bite & Hold, Non-Lethal Takedown, Prop Dragging,
  Handler-Down Defense — see "Before you trust the combat features in
  production" below before relying on these.
- **Wellbeing**: mood, fatigue, fear/stress, distraction, injury/limping
  — each independently switched, each with a small movement-speed
  effect when it's low.
- **XP/progression, K9 inventory, a K9 medkit, a vitality HUD, prop
  attachments (a cosmetic vest), fetch, a deployable kennel, a K9 supply
  shop, and a leaderboard.**
- **Handler Partnership** — a longer-term bond distinct from the leash,
  with an optional one-time tenure milestone XP bonus (see "Known
  limitations" below for the one real gap in its anti-farming guard) and
  a partner camera-feed toggle (full-screen view-switch to your
  partner's viewpoint, not a literal picture-in-picture — see below).
- **Five reaction/"hunting" features, easy to miss because they're new
  enough that even this resource's own internal history file hadn't
  caught up on them — all shipped, on by default, and worth knowing
  about specifically:**
  - **Find Alerts** — a search or completed track makes the K9
    automatically sit and bark, reacting differently depending on the
    outcome. No manual trigger, and it doesn't depend on the XP system
    being on.
  - **Scent Trail Hunt** — turns a search into a hunt: the K9 is guided
    only by a growl that gets stronger as it gets closer to a hidden
    spot. The location itself is never sent to the player's game, only
    the growl intensity — there is nothing to read the answer out of.
    No marker, no XP.
  - **Pursuit Sprint** — a short, cooldown-gated burst of genuinely
    extra speed for a certified K9 chasing a *wanted* target only.
    Every speed source this resource has (breed, XP tier, fatigue,
    this burst) is clamped to a combined maximum, so it can't be
    stacked into something an escaping target has no real chance
    against.
  - **Scent Lineup** — several players line up and must all explicitly
    accept; the server secretly picks one and reveals nothing until the
    K9 commits a single final guess. No XP, since the outcome is random.
  - **SAR Calls** — a hidden search-and-rescue target (a missing person
    or lost property); the K9 reacts more strongly on approach. Always
    resolves as a rescue, never an arrest, and the "target" is always
    scenery, never a real player without their consent.
  - All five need an individual grant from high command on top of their
    global switch by default (see `Config.FeatureControl.RequireGrant`
    in "The command tablet" section below) — nobody has any of them
    until high command hands them out one person at a time.
- **A training mode** — a practice sandbox against a scripted dummy;
  touches no real player, no real inventory, and awards zero XP.

---

## How a K9 gets made

Two ways, both server-authoritative:

- **Certify an existing department member.** A qualifying supervisor
  (or, by default, the officer themselves) grants a certification with
  `/k9certify` or the "Certify K9 Handler" ox_target option. The target
  does **not** need to already look like a dog — any member of an
  eligible department is a valid target.
- **High command assigns the role directly**, from the K9 Command
  Tablet, to any citizenid, with a chosen model.

By default (`Config.K9Appearance.applyPedModelOnCertify = true`), either
path **actually changes that player's character** into the configured
K9 ped — their original appearance is recorded first, so losing the
role (revoke, job change, or a high-command "revert") changes them
back. If you don't want this resource ever touching a player's
appearance, set `applyPedModelOnCertify = false`; certification then
behaves the old way — a pure access-control layer on top of a character
who already chose to look like a dog on their own.

The "K9 role" itself (what you're allowed to *do*) and "what you look
like" are independent: `Config.K9Appearance.requireK9ModelForRole`
(default `false`) means a role-holder on any model, including an
ordinary human, still gets every K9 ability. Every server-side check
re-verifies the role live — nothing about it is cached client-side or
trusted from what a player's game claims.

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

**One inventory choice has two real gaps worth knowing before you pick
it: `qb-inventory`.** If you set `Config.Compat.Systems.inventory.override`
to `'qb-inventory'` yourself, or just leave auto-detection to find it,
two specific player-facing things quietly stop working — no error, no
notification, nothing in the console:

- **The K9 supply shop never opens for players.** A handler walks up,
  clicks "Buy K9 Gear", and nothing happens at all. qb-inventory has no
  way for this resource to open a shop screen from the *player's* side
  (only from the server), so this is a permanent dead end on
  qb-inventory, not something a restart or a different setting fixes.
- **A search cannot see contraband hidden inside a bag or backpack
  item.** It still correctly finds anything sitting loose in someone's
  own inventory ("pockets") — only the *inside* of a separate bag item
  is invisible to it on this backend. A "clean" result can mean
  genuinely clean, or "hidden in a bag," and there's no way to tell
  which on qb-inventory.

Everything else — including the K9 medkit and finding contraband
sitting loose — works normally on qb-inventory. If you need the supply
shop to work for players, or need bag-searching to be trustworthy, use
`ox_inventory` (the one this resource is built and tested against)
instead.

**Dispatch integration covers one alert, not every K9 event.** If a
supported dispatch is detected, this resource automatically posts to
its board with zero setup for exactly one thing: a K9 going down. A
search-and-rescue call being completed and a contraband search
finishing both still announce themselves as an event your own scripts
can listen for (see "Public API for developers" below), but neither one
lights up a detected dispatch board on its own the way a K9 going down
does. That's a deliberate, narrower scope, not a missed connection —
if you want those to show up on your dispatch board too, someone needs
to write a small bridge that listens for the event and posts it there;
this resource doesn't do that step for you today.

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

   Prefer not to use the script, or have no shell access? Run
   `sql/install.sql` once (every `CREATE TABLE` is safe to re-run), then
   every file in `sql/migrations/` in filename order (also safe to
   re-run). Check `sql/migration_status.sql` any time to see what's
   actually applied.

   **If you are pasting into phpMyAdmin, Adminer or HeidiSQL**, use the
   tool's *Import a file* feature rather than its query box for the
   files in `sql/migrations/`. Five of them use a `DELIMITER` statement,
   which is a command those query boxes do not understand — you would
   get an unexplained syntax error partway through. `install.sql` itself
   pastes fine either way. **`sql/DATABASE_GUIDE.md` walks through all of
   this in plain English**, including turning the database off, taking it
   back out, and upgrading later; read it if any of the above is unclear.

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
than reading start to finish. Nearly every one of its `Config.Features`
switches ships **on** by default; the exceptions and what they mean are
covered below. (No count is given here on purpose — a hand-typed number
in a document goes stale the first time someone adds a feature.)

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
- **If you run (or are auto-detected onto) `qb-inventory`** — check
  `Config.Compat.Systems.inventory` in `config.lua` and read "About
  works with any inventory/dispatch/framework" above before you commit
  to it. Short version: the K9 supply shop won't open for players, and
  a search can't see contraband hidden inside a bag, on that specific
  backend only.
- **`Config.K9Vehicles`** — which vehicles a K9 can ride in. A K9 sits
  in a real seat (rear preferred, never the driver's) — visible to
  everyone else, not hidden or attached to the outside of the car.
- **`Config.TrainingZones`** and **`Config.K9EquipmentShop.locations`**
  — both ship with a single placeholder coordinate near Mission Row PD.
  Move them, or the training yard and the supply shop have nowhere real
  to be used from. (High command can also add/move/remove supply shop
  locations later from the tablet, without touching this file again.)
- **Create these items in your inventory script** — none exist on a
  fresh install. A missing one doesn't error; for a player it simply
  never works, with nothing on screen explaining why. (The supply shop
  is the exception: it prints a console warning naming any item it was
  asked to sell that your inventory doesn't have, so check the server
  console after a restart.) The items: `k9_medkit`, `k9_treat`,
  `k9_meat_bait`, `k9_ultrasonic_whistle`, and `k9_tablet` **only if**
  you set
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

### If you forgot to import the SQL, or only ran part of it

This is different from deliberately setting `Config.Database.enabled =
false` above — this is what happens if you skip, or only partly finish,
step 2 of "Installing" by accident.

The resource checks its own tables against the database on startup. It
never errors, crashes or half-works, and it always tells you plainly in
the server console what it found. What it does next depends on what is
missing:

- **Every table missing** — the SQL was never imported. Nothing is saved
  this session; the resource runs entirely from memory, exactly as if you
  had set `Config.Database.enabled = false`. Everything still works for
  everyone playing; it just forgets when the server restarts.
- **Some tables missing** — usually `sql/install.sql` ran but a later
  file in `sql/migrations/` didn't, or a table was dropped since. Only
  the missing tables fall back to memory. Everything else keeps saving
  normally. The console names the missing tables and what each one is
  for, so you can see exactly what is not being kept.
- **A table exists but isn't ours** — something else in your database
  already owns a table with one of our names. This one stops the resource
  using the database at all, on purpose, because writing into a table
  belonging to another resource is a different and much worse problem
  than forgetting something.

One deliberate exception to the middle case: if the certifications table
is missing, specializations fall back with it even if that table is fine.
They are only meaningful together — keeping specializations while
forgetting the certification behind them could hand someone back a
specialization nobody granted.

The fix is the same either way: run through step 2 of "Installing" above
(`k9_setup.sh`, or `sql/install.sql` plus everything in
`sql/migrations/` in order) and restart the resource — check
`sql/migration_status.sql` if you want to see exactly what's applied
before you do.

*(A more detailed, owner-facing walkthrough of the install/uninstall
story — including the rollback scripts under `sql/rollback/` — is being
finalized separately and will expand this section; the behavior above is
verified against the current code, not a guess.)*

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
fixed, and by owner request now goes further than just fixing that one
deadlock:** `Config.FeatureControl.allowHighCommandSelfGrant` (default
`true`) lets a high-command officer grant *any* permission this catalog
covers to their own citizenid — the `feature.<Name>`/`block.<Name>`
grants above, **and now also the four named capabilities**
(`k9.access`/`k9.certify`/`k9.audit`/`k9.givexp`). Separately,
`Config.HighCommand.allowSelfGrant` (also default `true`) covers
granting **XP** to yourself via `/k9givexp`. Both are the owner's own
explicit decision ("high command can grant anything they want to
themselves") rather than just a deadlock fix, and neither is hidden:
every self-grant is still fully logged, tagged explicitly as a
self-grant in the audit trail rather than just showing the same
citizenid twice. Set either flag back to `false` on your own server if
you'd rather require a second high-command officer's sign-off before
someone can grant themselves a permission or XP — know that doing so
also brings back the original solo-owner deadlock for the Audit tab
specifically, until a second high-command officer exists.

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
operating this resource. One other file is written for you as the
server owner; the rest are for a different reader and none of them are
needed to get this resource running:

- **`sql/DATABASE_GUIDE.md`** — written for you, in plain English, if
  anything about the database step is unclear. Covers installing without
  shell access, turning the database off, taking it back out of your
  database later, and upgrading. Read it if step 2 above gave you any
  trouble.
- **`DEVELOPER_REFERENCE.md`** — for anyone modifying this resource's
  code: full exports/events contracts, internal design, and file-by-
  file behavior.
- **`KNOWN_ISSUES.md`** — bugs and disclosed limitations, for whoever
  maintains the code next.
- **`PROJECT_HISTORY.md`** — what shipped and when.
