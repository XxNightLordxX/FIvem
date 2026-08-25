# qbx_k9unit — Status & Decisions

**Measured 2026-08-25**, by reading `config.lua` and the current test suite
directly — not copied from an older document. This file used to be two
separate documents (`PROJECT_STATUS.md`, a snapshot of how the project was
doing, and `DECISIONS_NEEDED.md`, a list of calls only you can make). They
are merged here on purpose: "what needs your decision" is part of "where
things stand," and keeping them in separate files was exactly why decisions
were getting missed.

**This project is being worked on by several people at once, right now.**
Anything below can go stale within hours. If it's been more than a day
since the date above, ask whoever is actively working on this project
whether something changed, or check the specific thing yourself (this
document says how, item by item).

## Words used in this document

- **Resource** — an add-on a FiveM server installs. "This resource" means
  this K9 add-on.
- **Feature flag** — an on/off switch in `config.lua` (each one is a line
  like `Config.Features.SomeName = true`). Only whoever manages your
  server's files can change one. Flipping a flag on doesn't just turn on
  a menu option — it also turns on the server-side code behind it.
- **Native** — a built-in game engine function this resource calls (e.g.
  "make this object visible," "check this player's health"). Mentioned
  below only where it matters to a decision.
- **netId ("network ID")** — the number the game uses to identify one
  specific object/vehicle/ped across every connected player's game at
  once, so "delete this exact kennel" can't accidentally mean "delete
  someone else's kennel."
- **ACE permission** — a named permission your server grants to specific
  people (usually staff), separate from any in-game job or rank. A few
  features below only work for someone your server has explicitly granted
  one to.
- **Citizen ID** — the permanent ID for one specific player character,
  used any time a record needs to survive that person disconnecting or
  changing jobs.
- **Migration** — a small script that updates an existing database to
  match a newer version of this resource, run once by whoever manages the
  server's database.
- **Cooldown** — a required wait before an action can be repeated. Used
  throughout this resource to stop spam and stop players from earning
  rewards too fast.
- **XP farm** — a way to earn far more in-game experience than intended,
  for far less real effort or risk, by exploiting how a system is
  triggered rather than by actually doing the work it's meant to reward.

---

## The one-paragraph version

**39 of this resource's 40 feature flags are now switched on** —
confirmed by reading `config.lua` directly on the date above, not assumed
from an older note. That includes features this project had deliberately
kept off pending a safety/balance review, most importantly the three
combat features and a developer-only tool that its own code comment says
should never run on a live server (see the next section — read it first).
The one exception is `CameraFeedPiP`, which has no implementing code at all
(see the table below) and has been corrected back to `false` after briefly
being swept to `true` along with everything else — flipping it either way
changes nothing in-game. Two open safety questions about the combat features
(D3 and D13, below) still have **no answer**. Turning the flag on did not
answer them — it just means whatever risk they describe is live on your
server now, not hypothetical. This resource's test suite has grown to 23
spec files (up from 17); re-run `tests/run.sh` yourself for a current
pass/fail count and `luacheck`/`luac5.4 -p` for lint/syntax — this document
was written without shell access and could not re-execute either itself
this pass, only confirm the file count directly. Passing tests tell you the
code does what its authors intended — they do not tell you the two open
questions below are resolved, because neither is something a test can
check.

---

## Read this first — one setting that should not stay on

**`Config.Features.BoneSweepDevTool` is currently `true`.**

Plain version: this turns on a hidden command (`/k9bonetool`) that lets
whoever has a specific staff permission spawn and attach real objects in
the game world, on demand, in front of any player. It exists purely so a
developer can figure out exactly where a cosmetic vest should attach to a
dog's body — a one-time, private test-server job. The code that builds
this feature says, in its own words, **"never enable this on a production
server."** Right now, on this server, it is enabled.

It's ACE-gated (see the glossary above), so a random player can't reach it
— but the flag itself, not the permission, is described in this
resource's own documentation as "the real switch," and the real switch is
on.

**What to do:** ask whoever manages this server's files to open
`config.lua`, find `BoneSweepDevTool`, set it back to `false`, and restart
the resource (not just save the file — the command stays reachable until
an actual restart, even after the switch is flipped back). This is the
single most urgent item in this whole document.

---

## What's live right now, grouped by area

39 of the 40 flags are `true` (the exception, `CameraFeedPiP`, is explained
in its own row below). Grouping them tells you more than a flat list — some
groups are low-risk now that they're on, some carry real, still-open
questions.

| Group | What it covers | Should you worry? |
|---|---|---|
| **Core (Phase 1)** | Leash, radial menu, vehicle load/unload, basic bark, jump/crouch | No — this is the original, most-reviewed part of the resource, re-verified conformant repeatedly. |
| **Tracking & search** | Scent/blood/gunpowder trailing, vehicle/person search, contraband alerts, thermal/night vision, door interaction | Low. Nothing here restrains, damages, or moves another player. One real to-do: `Config.SearchContrabandItems` still lists placeholder item names (`weed_bud`, `coke_brick`, etc.) — swap these for your own server's real item names, or searches won't find anything real. Also see D6 below (a live check that was never run). |
| **Combat** | Bite & Hold, Non-Lethal Takedown, Dragging, Handler-Down Defense, the Handler Partnership registry, Recall | **Yes — see D3 and D13 below before treating this as safe.** A cheater can already shrug off the restraining half of these mechanics on a modified client; that's disclosed and accepted by turning them on, not a new problem. What's *not* settled is whether the security check meant to stop a different exploit (self-granted invincibility) actually works the way this project believes, and whether a griefing exploit against `FearStressSystem` (also now on) is something you're willing to live with. |
| **Inventory, XP, wellbeing** | K9 gear stash, K9 medkit, XP progression, Fatigue/Mood/Fear-Stress/Distraction/Injury | Low risk to other players, but every number driving these (XP awards, thresholds) is still an unreviewed placeholder — see "placeholder numbers are now live money" below. |
| **Audio, props, kennel** | Advanced bark variants, proximity audio, cosmetic vest, fetch, deployable kennel | Low. Two are cosmetic-only and known to look wrong until a one-time dev task is done (D8/D9 below); most bark/ambient sounds are still silent because the audio files don't exist yet (see D7). |
| **Admin & developer tools** | The read-only admin/audit commands, the bone-sweep dev tool | The audit commands are safe by design (read-only) and are gated by **police job rank**, not an ACE permission — a senior-enough rank in a department listed in `Config.Departments` (or that department's boss) can already run them, with no separate staff grant needed at all. This changed 2026-08-25; there is no more ACE permission to configure for these specifically. **The bone-sweep tool is different and is still ACE-gated** (a separate permission, unrelated to police rank, because it's a dev tool, not a police capability) — see the urgent warning above; that one is genuinely not safe to leave on. |
| **Not really a feature** | `CameraFeedPiP` | Currently `false` again after briefly being swept to `true` along with everything else — corrected because no code exists behind it either way. The idea (a live camera feed) has been confirmed genuinely impossible with the game engine's current capabilities, not just unbuilt. Harmless regardless of which way this flag is set. |

---

## Two decisions that need a human, not more code

Both of these gate the combat group above, which is now switched on. Turning
the flag on did not close either question — it made both of them live
questions about your actual running server instead of a "before you enable
this" caveat.

### D3 — Does a security check actually work the way this project believes?

**Plain version:** there's a check meant to stop a player's own game client
from faking a message that's supposed to come only from the server — the
exact hole that once let a player grant themselves invincibility with
every feature switched off. It's the standard, officially-documented way
the game engine's own makers say to guard against this, and it's applied
everywhere in this resource now.

**The problem:** nobody has been able to prove, by reading code alone, that
it can't be tricked under one specific, realistic sequence: a player who
has already received one genuine message from the server, then tries to
fake one themselves. Four separate attempts to settle this by reading the
game engine's own source code have all hit the same wall — the part that
actually decides this isn't in any file that can be read from outside the
engine's own private build process.

**Why this can't just be fixed in code:** this isn't a bug in this
resource to patch — it's a question about how the game engine itself
behaves. The only way to know for sure is a real test on a real, running
server: connect a test account, let it receive one genuine message from
the server, then try to fake one from that same connection, and see what
happens. It takes about five minutes. As of this document, **nobody has
run it.**

**What this blocks:** trusting Bite & Hold, Non-Lethal Takedown, and
Dragging as actually secure — all three are switched on right now, leaning
on this exact, unverified check.

**Your call:** trust it as shipped (it's applied everywhere, and is
strictly better than nothing), or run the five-minute sequenced check
before trusting these combat features with real players. Do not settle
this by reading more code — only the live test settles it.

### D13 — Is a limited griefing exploit acceptable on your server?

**Plain version:** with `FearStressSystem` on (it now is) alongside the
combat features (also on), any player standing nearby a K9 — a total
stranger, no relationship to that K9 or its handler required — can
repeatedly send a signal that says "there's gunfire nearby" and force that
K9 to refuse Bite & Hold / Takedown commands for about a minute at a time,
for as long as they want to keep doing it. This costs the attacker
essentially nothing.

**What's already fixed:** a single episode can no longer last forever —
after about 64 seconds it resets automatically, and the attacker has to
start over. This is a real fix, not just a comment; it's been confirmed
directly in the code.

**What's still open:** the *repeatable* version. Someone can force that
64-second lockout again and again. There's no code fix for this — the
underlying signal ("I heard gunfire nearby") has no way to verify who
actually fired a gun, by design, the same tradeoff this project already
accepted for a lower-stakes feature (scent tracking).

**The actual decision:** is a repeatable, low-effort way to jam one K9's
combat commands for about a minute at a time, with no relationship to that
K9 required, an acceptable cost on your server, given the realism it buys?
This is a judgment call about what kind of server you want to run — not
something more code can answer.

---

## Everything else that used to live in `DECISIONS_NEEDED.md`

Most of these are no longer decisions waiting on you — either they were
already answered, or your choice to enable every flag has answered them by
implication. Kept here so nothing quietly disappears.

**Already answered by turning everything on:**
- *Which features do you want on, and which should wait for review first?*
  Answered: all of them, now. The tracking/search group was the
  lowest-risk recommendation; combat was the highest-risk. Both are on.
- *Accept that a modified client can ignore the restraining half of combat
  effects, or keep those features off?* Answered by turning combat on —
  this project logs non-compliance but never punishes it automatically
  (the only allowed responses are `'log'` and `'notify_staff'`, never an
  automatic kick or ban), which limits the damage a false positive from lag
  could do.

**Already fixed in code — nothing left to decide, mentioned for completeness:**
- Two XP-farming defects (a dead scent-range bonus that never actually
  worked, and a way to replant your own contraband and get paid for
  finding it repeatedly) were found and closed. If you want to retune the
  actual numbers (still placeholders — see below), that's optional, not a
  fix that's owed.
- Dependency version pinning: FiveM has no way to pin a dependency's
  version in `fxmanifest.lua` at all — confirmed against the game engine's
  own source. Nothing to decide here; this resource instead documents
  "last version checked" (see `README.md`) and, for `ox_inventory`
  specifically, checks at startup that the feature it needs actually
  exists before using it.

**Now urgent, because the feature they gate is live rather than pending:**
- **Scent tracking's one-time live check was never run.** `ScentTracking`
  is on right now, but the exact shape of the data it reads from
  `ox_inventory` was only confirmed by reading that other resource's
  source code, never by testing against a real, running install. The
  five-minute fix: drop an item as a certified K9 handler on your actual
  server, and read the logged data once to confirm it looks like what this
  resource expects. If it doesn't match, scent tracking will misbehave
  quietly rather than crash.
- **The cosmetic vest and fetch-carry attach at the wrong point on a dog's
  body.** Both features are fully playable, but the attachment point is
  currently a placeholder (the root of the skeleton), so they'll look
  visibly wrong. A developer-only sweep tool exists to find the correct
  spot — see the urgent warning above for why that tool must be turned
  back off immediately after use, and never left on.
- **The deployable kennel's object model was swapped after a prior model
  was found not to exist**, based on the best evidence available
  (`prop_dog_cage_01`, confirmed to exist in a real object database with a
  screenshot) but not yet confirmed by actually placing one and looking at
  it. Low stakes: if it's ever wrong, a real, working fallback object
  appears instead of a broken one — but worth a two-minute check now that
  the feature is live.

**Bark and ambient audio — partly resolved, partly still your call:**
The single sound needed for the default "Bark" action (`bark.ogg`) has
been sourced under a permissive, attribution-only license and is
confirmed wired up to actually reach players — this one already works.
Four more sound files (three alternate barks, one ambient growl) used by
optional features that are now switched on are still silent, because no
audio file has been supplied for them yet. Every real candidate found
requires giving credit to the original creator; none is public domain.
That's a small, one-line-of-credit-text decision for whoever runs this
server, not a blocker — accept an attribution-only license, accept a
share-alike one (a heavier condition, worth reading about before
accepting), commission your own, or leave those specific sounds silent.
See `AUDIO_SOURCING.md` for the details.

**A version number is overdue.** This resource is still labelled `0.1.0`.
Given that every flag is now on, a real version bump (not just to `0.2.0`
— substantially more has landed since that number was drafted) is worth
doing so anyone tracking this resource elsewhere can tell "the everything-on
configuration" apart from the original narrow release.

---

## Placeholder numbers are now live, not theoretical

Every number that decides how much XP an action pays, how much contraband
weight triggers which alert, and similar tuning values, is still marked in
`config.lua` as an unreviewed placeholder — drafted for realism, never
checked against real play. That was a low-stakes note while those systems
were switched off. **It is not low-stakes now.** With XP progression,
wellbeing, and contraband alerts all live, these numbers are actively
shaping what your players can earn and how, starting today. Nothing here
is broken — the known XP-farming loopholes have been closed — but nobody
has confirmed the *remaining, intended* numbers feel right for your
server. Worth a look before this runs unattended for weeks.

---

## What's actually been tested, as of the last time someone ran it

- **Automated tests:** the test suite has grown to 23 spec files (this
  document's own earlier "698 checks across 17 files" line was stale — file
  count re-verified directly by listing `tests/*_spec.lua` on the date
  above). This pass had no shell access to re-run `tests/run.sh` itself, so
  it cannot personally certify a current pass/fail count — run it yourself
  if that matters to you right now.
- **Lint and syntax:** run `luacheck` and `luac5.4 -p` yourself for a
  current answer; not re-run by this pass for the same reason as above.
- **Nothing is dead code:** every `.lua` file on disk is wired into
  `fxmanifest.lua`, the file that tells the game which scripts to actually
  send to players.

None of this tells you the two open decisions above are resolved — a test
suite checks that code does what its own author intended, not whether the
underlying design choice (D3, D13) is safe. Keep them separate in your own
head, because it's easy to read "all tests pass" as "everything is fine."

---

## Mistakes this project has made before (so you know the pattern)

Carried over from `DECISIONS_NEEDED.md`'s own retrospective section, so this
doesn't get lost when that file is deleted. None of these are still open —
they're listed because a document that only reports successes isn't worth
trusting, and because the next thing built on this resource is more likely
to repeat one of these than invent a new mistake:

- **A setting once claimed to restrict access when it didn't.** A config
  comment said a K9 gear-stash setting limited access to that K9's own
  player. It never actually did, because the check it relied on doesn't
  look at identity at all. It's now impossible to even set that value —
  the resource refuses to start rather than silently grant broader access
  than documented.
- **A file's own comment claimed a certification revoke automatically ended
  that handler's partnership.** The code to do that existed, but nothing
  ever called it, so it silently never happened until someone checked the
  claim against the code and wired the missing calls in.
- **A commit message described a fix that wasn't actually in that commit.**
  The bug it claimed to fix had already been fixed moments earlier by a
  different, unrelated change. No bug ever reached a player, but it's a
  reminder that a commit message saying "fixed" isn't proof the fix is in
  that specific commit.
- **A code comment said a screen effect applied to the wrong player.** It
  said a contraband-search visual effect applied to the *searched* person's
  screen; the code has always applied it to the *searching* K9's own
  handler, as feedback for them, not a penalty on a suspect. The comment
  was wrong, not the code — but trusting the comment alone could have led
  someone to "fix" working code into penalizing the wrong player.
- **A shipped feature referenced a visual effect that didn't exist**, so it
  would have run with no error and no visible effect, forever, with nothing
  in any log explaining why. Found by checking the name against the game's
  own data directly, not by trusting the code comment; fixed to the real
  name.
- **A security bug, once fixed, reappeared in a copy-pasted file.** An
  unguarded "delete this object" handler let a forged message delete any
  object in the world, not just the one it was supposed to. Fixed once in
  the original feature, then found and fixed again in a newer feature that
  had copied the same pattern — including its bug.

---

## What I could not verify

- The exact, low-level way the game engine decides a message really came
  from its own server (what D3 hinges on) — this lives inside the engine's
  own private source, not readable from here. Only the live test described
  in D3 can settle it.
- Whether anyone has already flipped `BoneSweepDevTool` back off since this
  document was written — re-check `config.lua` directly; this is the one
  fact in this whole document most worth re-verifying yourself before
  acting on anything else here.
- Whether the placeholder numbers mentioned above have been retuned by a
  concurrent pass — check `config.lua`'s own comments for a more recent
  date than the one at the top of this document.
