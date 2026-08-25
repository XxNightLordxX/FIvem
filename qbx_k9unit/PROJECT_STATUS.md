# qbx_k9unit — Project Status

**Measured:** 2026-08-25, against commit `9808e56` (184 commits on this
branch). Written by the release-manager pass, read-only on code — no
`.lua`, `config.lua`, or `fxmanifest.lua` file was touched to produce this
document.

**Before you trust this:** this project is being worked on by many people
at once, right now, in parallel. Two earlier versions of this exact
document went stale within about a day of being written. If it's been more
than a few hours since the date above, ask whoever's actively working on
this project whether more has landed, or run `git log --oneline -20`
yourself before relying on anything below.

## The short version

- **Five basic features work today and ship switched on**: leash control,
  the K9 radial menu (a pie-shaped quick-select menu), getting a K9 in and
  out of vehicles with its handler, basic jumping, and a bark sound that —
  see below — doesn't actually make a sound yet.
- **A large amount of further work is fully built and tested, but switched
  off on purpose.** Tracking dogs, search dogs, combat assistance,
  inventory restrictions, an XP/fitness system, deployable kennels, and
  fetch are all finished code, not placeholders. They're off because
  someone needs to review and approve them before they go live on a real
  server, the same way this project has treated every new feature all
  along.
- **Two decisions are blocking the combat features specifically, and
  neither can be settled by writing more code.** See section 3.
- **Automated checks**: 698 individual test cases across 17 files, all
  passing — I ran the suite myself. Lint and syntax are also clean — I ran
  those myself too, not copied from a comment.

## 1. What works today (switched on by default)

A feature flag is an on/off switch in `config.lua` (`Config.Features.X`).
Five of the 40 that exist are `true` (on); the other 35 are `false` (off).
The five that are on:

- **`LeashMechanics`** — officers can leash and unleash a K9.
- **`RadialMenu`** — the K9 quick-select menu is available in-game.
- **`VehicleEntryExit`** — a K9 can get in and out of vehicles alongside its
  handler.
- **`AgilityBasicJump`** — a K9 can jump and crouch using the game's own
  built-in animations. It cannot yet vault over fences or through windows —
  that's a separate, still-off feature (`AgilityAdvanced`).
- **`BasicBarkSounds`** — the code that's supposed to play a bark sound
  runs, but **there is still no actual sound file behind it**, so nothing
  plays. This has been true since the feature was first built. It's a
  disclosed gap, not a bug, and not something that will error or crash —
  see section 5 for exactly where this stands right now.

## 2. What's built but switched off, and why

**Tracking & search** (`ScentTracking`, `BloodTracking`,
`WaterTrackingDecay`, `GunpowderSniffing`, `SearchZones`,
`ContrabandAlerts`, `ThermalVision`, `NightVision`, `DoorInteraction`) —
fully built and the most reviewed part of this project. Using these
features doesn't affect any player who isn't already part of the search
in progress, which makes this the safest group to turn on first. One
thing to fix before you do: the example contraband item list in the
config uses placeholder item names — swap those for your own real item
names first.

**Combat & backup** (`BiteAndHold`, `NonLethalTakedown`,
`HandlerDownDefense`, `PropDragging`, plus `Recall` — the handler's "call
your dog off" escape hatch — and `HandlerPartnership`, the registry these
depend on) — fully built. Six separate ways a player could have farmed XP
unfairly (earned far more than intended for far less effort or risk) were
found and closed over the course of this project. **This whole group is
blocked from going live by two open decisions, not by missing code** — see
section 3.

**Inventory, XP, and K9 wellbeing** (`K9Inventory`, `XPProgression`,
`HealthStaminaHUD`, `FatigueSystem`, `MoodSystem`, `FearStressSystem`,
`DistractionSystem`, `InjuryLimping`, `K9Medkit`, `ContrabandScreenFX`) —
fully built. The numbers driving XP tiers and contraband-alert thresholds
are still placeholders, meant to be tuned to your own server's economy
before you turn this group on — that's a numbers-tuning task, not a defect.

**Audio, props, and kennels** (`AdvancedBarkRadial`, `ProximityAudioFX`,
`PropAttachments`, `FetchMechanic`, `DeployableKennel`, `CameraFeedPiP`) —
mixed:
- `DeployableKennel`, `PropAttachments`, and `FetchMechanic` are built and
  tested, held back by one small polish item — the point where a prop
  attaches to a K9's body still uses a placeholder position instead of a
  fitted one.
- `AdvancedBarkRadial` and `ProximityAudioFX` are built but, like
  `BasicBarkSounds` above, need real sound files before they'd do anything
  audible. See section 5.
- `CameraFeedPiP` (a picture-in-picture, bodycam-style camera view) is
  **genuinely not built, and can't be right now** — the game engine simply
  doesn't have the capability yet. This was checked directly against an
  open, unresolved request to the game engine's own developers, not
  assumed. This isn't a "coming soon" item; it's currently impossible.

## 3. Two decisions that need a human, not more code

### D3 — Does a security check actually work the way we think it does?

**Plain version:** there's a check meant to stop a player's own game client
from faking a message that's supposed to come only from the server. It's
the standard, officially-documented way the game engine's own makers say
to guard against exactly this, and it's now applied everywhere in this
project.

**The problem:** nobody has been able to prove, just by reading the code,
that it can't be tricked under one specific and realistic sequence of
events (a player who has already received one real message from the
server, and later tries to fake one themselves). Four separate attempts to
answer this by reading the game engine's own source code have all hit the
same wall — the part of the engine that actually decides this isn't in any
file that's possible to read from outside the engine's own private build
process.

**Why we can't just fix this in code:** this isn't a bug in our code to
patch — it's a question about how the game engine itself behaves. The only
way to know for sure is to run a real test on a real, running server:
connect a test account, let it receive one genuine message from the
server, then try to fake one from that same connection, and see what
happens. It takes about five minutes. As of this document, nobody has run
it yet.

**What this blocks:** `BiteAndHold`, `NonLethalTakedown`, and
`PropDragging` — the combat features that lean on this specific check the
most.

### D13 — Is a limited griefing exploit acceptable on your server?

**Plain version:** once you turn on `FearStressSystem` (a feature that
makes a K9 hesitate under stress, still off by default) together with the
combat features, any player standing nearby — a total stranger, with no
relationship at all to that K9 or its handler — can repeatedly send a
signal that says "there's gunfire nearby" and force that K9 to refuse
bite/takedown commands for about a minute at a time. They can keep doing
this for as long as they want to stay nearby.

**What's already fixed:** a single hesitation episode can no longer last
forever — it automatically resets after about a minute, so this was
already tightened once. What's left is the bounded, repeatable version:
someone can still force that one-minute lockout again and again, at almost
no cost or effort.

**Why this isn't a bug for a programmer to fix:** the underlying signal
("I heard gunfire nearby") has no way to verify who actually fired a gun —
that's true by design, the same way this project already accepted for a
lower-stakes feature (scent tracking). There's no code change that closes
this without removing the feature's whole premise.

**The actual decision:** is a bounded, repeatable, low-effort way to
annoy one K9 and its handler for about a minute at a time an acceptable
cost, in exchange for the added realism, on your server's live PvP? That's
a judgment call about what you want your server to be like — not something
this project can answer for you.

## 4. Automated checks (run directly for this document)

- **Tests:** `tests/run.sh` — 17 spec files, 698 individual checks, all
  passing.
- **Lint:** `luacheck` — 67 files, 0 warnings, 0 errors.
- **Syntax:** every `.lua` file in the project parses cleanly
  (`luac5.4 -p`).
- **Nothing is "built and forgotten":** every `.lua` file on disk is listed
  in `fxmanifest.lua` (the file that tells the game which scripts to send
  to players) — 25 client files and 22 server files, matched one-to-one.
- **In-game text:** `locales/en.json` holds exactly 306 entries, one per
  piece of text a player can see. Counted directly from the file, not
  estimated.

## 5. The K9 bark sound, right now, at the moment this was checked

`BasicBarkSounds` has shipped switched on without an actual sound file
behind it since it was first built — that's been disclosed the whole time,
not hidden. The wait has been for a properly licensed sound (see
`AUDIO_SOURCING.md` for the full reasoning on where to get one and why an
earlier candidate was wrongly ruled out).

**As of the exact moment I checked:** a real, working sound file exists
inside the project folder, and I confirmed it genuinely is a valid sound
file, not a placeholder. But it has **not yet been saved into the
project's permanent history**, and it has **not yet been added to the
list of files the game actually sends to players**. Until both of those
happen, players still won't hear anything — so as of right now, nothing
has changed for anyone running this resource. This looks like someone
else's work in progress, not something that needs your attention today.

## 6. Other work in progress in the shared project folder right now

Besides what's recorded in `CHANGELOG.md`, a few more not-yet-finished
edits were sitting in the project folder at the exact moment I checked —
normal for a project several people are actively editing at once, not a
warning sign by itself:

- The new bark sound file and an updated credits/attribution note
  (section 5).
- More test coverage being written for the admin commands, and a
  brand-new test file for the "call your K9 off" safety feature.

None of this is reflected in the numbers in section 4 except where noted,
since none of it has been saved to the project's history yet.

## 7. What I could not verify

- **The exact, low-level way the game engine decides a message really came
  from its own server** (what decision D3 depends on) — this lives inside
  the engine's own private source, which isn't available to read. It can
  only be settled by the live test described in D3.
- **Whether the dependency versions this project lists (`qbx_core`,
  `ox_lib`, and so on) are still current** — that's tracked separately, by
  whoever's checking dependencies, not re-verified here.
- **Whether the in-progress edits in section 6 will be finished as-is,
  changed, or dropped** before they're saved to the project's history — I
  only saw one snapshot in time.
