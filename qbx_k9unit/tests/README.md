# qbx_k9unit automated tests

## What this is

This folder holds automated tests for qbx_k9unit's Lua code — mostly server-side code, plus one client-side file. An automated test is a small script that runs the real game-resource code and checks it behaves correctly, without needing a running FiveM server.

To run them, open a terminal in this folder and run `./run.sh`. A passing run prints `[PASS]` next to every check and ends with `ALL SPEC FILES PASSED (N file(s))` (41 as of 2026-08-25, see "The numbers below expire" — this count moves often). Anything else — any `[FAIL]` line, or a message like `SPEC FILE(S) FAILED: ...` — needs attention. Before you assume the code is broken, though, read "Two false alarms" below: there are two specific situations that make this suite go red for reasons that have nothing to do with a bug.

Before this suite existed, the only safety net for this resource was `luac5.4 -p` (checks the Lua is written correctly) and `luacheck` (flags unused/undefined variables). Neither one can catch a *logic* bug — code that runs without error but does the wrong thing. Several real bugs found in QA passes on this resource (players farming XP, a way to steal another player's networked item, a tracking-data bug, a bug that could lock a player out of an ability) would all have been caught by a test like the ones in this folder.

## Terms used in this document

- **Spec file** — one test file, always named `something_spec.lua`. Each spec file tests one production file (e.g. `admin_spec.lua` tests `server/admin.lua`).
- **Sandbox** — a small fake FiveM environment that lets a real, unmodified production `.lua` file run under plain Lua, outside an actual game server. Explained in full below.
- **Fixture** — a helper function that builds one ready-to-use sandbox for a test, so each test doesn't have to set one up from scratch.
- **Stub** — a fake stand-in for something the real code calls, used when the test doesn't want that thing to actually happen. Example: a fake `TriggerClientEvent` that just records what it was called with, instead of really sending a network message.
- **Locale key** — a short name, like `combat.no_target_in_range`, used to look up a real piece of player-facing text in `locales/en.json`. Full explanation in `locales/README.md`.

## Running the tests

```sh
cd qbx_k9unit/tests
./run.sh
```

You need `lua5.4` installed and on your `PATH` — the same Lua version the real FXServer runs. If it's missing, `run.sh` tells you and stops; install Lua 5.4, or set `LUA_BIN=/path/to/your/lua5.4` to point at a specific binary. Nothing else needs installing — no framework, no package manager.

A passing run ends with:
```
ALL SPEC FILES PASSED (41 file(s))
```
(41 as of 2026-08-25 — see "The numbers below expire" below; this changes often.)
A failing run instead prints `SPEC FILE(S) FAILED: <names>` and exits with a non-zero status, which is what a CI job checks for.

### Two false alarms — read this before you panic at a red run

**1. A half-finished spec file turns the WHOLE suite red, not just that one file.**

`run.sh` runs every file in this folder matching `*_spec.lua`. If a new spec file is mid-write — a typo, a missing `end`, an unfinished test — `./run.sh` reports the ENTIRE suite as failed, even though every other, already-finished spec file is fine.

- **Symptom:** `./run.sh` reports a failure, but you haven't changed anything yourself.
- **Cause:** some spec file in the folder (yours or someone else's) is mid-write.
- **What to do:** run the files you actually care about one at a time instead of the whole suite, e.g. `lua5.4 admin_spec.lua`. Only trust a full `./run.sh` run once every file in the folder is finished. This is a normal side effect of several people editing this folder at once — not a sign the tested code regressed.

**2. If `locales/en.json` is mid-write, tests fail with a "locale key missing" error — which can mean two different things.**

Every test sandbox uses the REAL `locale()` function against the REAL `locales/en.json` file (explained in full below). If code being tested asks for a key that isn't in `en.json` yet, `locale()` raises an error and the test fails loudly, with a message like:

```
locale key missing from locales/en.json: some.key
```

- **Symptom:** that exact error message.
- **Cause A (a concurrency artifact, not a bug):** `en.json` is being edited right now — someone is adding or renaming keys, and the file is momentarily incomplete.
- **Cause B (a real bug — this has actually happened):** the production code asks for a locale key that was never added, or that was renamed/removed by mistake, and nobody noticed. This exact mechanism has already caught a real, shippable bug this way, not just a test artifact.
- **What to do:** check whether `en.json` is currently being edited. If yes, that's Cause A — just re-run once the edit is finished. If `en.json` looks finished and the key genuinely isn't in it, that's Cause B — treat it as a real bug report and fix the mismatch (add the missing key, or fix the call site). Don't assume "it's just concurrency" without checking; that assumption is exactly how a real bug slips through.

## Why plain lua5.4, and not a framework like busted

`busted` (a common Lua test framework) is installed on this machine, but only for Lua 5.1. This resource runs on Lua 5.4 (its own `.luacheckrc` pins `std = "lua54"` to match the real FXServer), and a Lua-5.4-compatible `busted` couldn't be installed here. A test suite that runs under a different Lua version than the real server can pass while hiding a real bug — one test in `admin_spec.lua` (`ClampLimit`'s handling of NaN/infinity) depends on exactly how this specific Lua build's `tonumber` behaves, which could differ under Lua 5.1.

So instead: this suite runs directly against the real `lua5.4` binary, with `testkit.lua` (about 100 lines) providing `test(name, fn)` plus a handful of checks (`equals`, `isTrue`, `isNil`, `contains`, and similar). Each spec file is a small, self-contained script: it loads `testkit.lua`, runs its own tests, and exits 0 (all passed) or 1 (something failed). `run.sh` just runs every spec file and reports whether any of them failed.

## How production code gets tested without a real FiveM server

FiveM-only functions — `GetGameTimer`, `TriggerClientEvent`, `MySQL.*`, `exports.*`, and so on — don't exist under plain Lua. `fixtures/sandbox.lua` solves this by loading a real, UNMODIFIED `server/*.lua` file into a sandbox: an environment pre-filled with small stand-in functions for just the handful of FiveM natives that specific file actually calls. This works without changing the production file at all — the real logic runs, for real, inside the test.

### `locale()` inside the sandbox is real, not a stub

Almost everything else in a sandbox is a stub (a fake). `locale()` is the one deliberate exception — it really reads and parses `locales/en.json`, the same way the real game does. Two consequences:

- When a test runs code that calls `locale('some.key')`, that call really looks up `some.key` in the real `en.json` file.
- Unlike the real game (which just quietly shows the key's name itself if the key is missing — the kind of bug a player might not even report), the sandbox's `locale()` throws a loud error on a missing key. See "Two false alarms" above for how to tell whether that error is a real bug or just `en.json` being mid-edit.

Because of this, every test that checks a notification message is *also*, for free, a check that the locale key behind it still exists in `en.json`. When you write a new test that checks notification text, build the expected text by calling `Sandbox.locale('some.key')` yourself rather than typing the English sentence into the test by hand — that way the test can never silently drift from what `en.json` actually says.

One real limit: a `local function` inside a production file can only be reached the same way a real caller reaches it — through something like a `RegisterCommand` handler or a registered event. Tests here never copy a local function's internal logic into the test itself. Where there's genuinely no real way in, that's written up as a gap in "What's NOT covered" below, not worked around.

## What's covered

| File | What's tested | How it's reached |
|---|---|---|
| `server/cooldowns.lua` | The shared cooldown/mutex helpers (`NewCooldown`, `NewNestedCooldown`, `NewMutex`): checking, stamping, consuming, clearing, and failing safely if given a bad threshold. Also per-player cleanup on disconnect and the background sweep that evicts stale entries. | Directly — these are all globals in the file, so tests call them straight. |
| `server/admin.lua` | `ClampLimit` (see the odd-number section below), citizen-ID and plate validation, admin-permission checks (ACE grants, console trust, checking permission before even looking at the arguments), the shared audit rate limit, and result-sorting. Also the file's own `NotifyPlayer` wrapper. | Mostly indirectly — through the real `RegisterCommand` handlers, checking the real SQL text and notification content they produce. |
| `server/progression.lua` | XP-tier lookup at exact thresholds, awarding XP (including guards against unknown actions, bad citizen IDs, and disabled features), the per-player XP rate limit, and cache cleanup on disconnect. | Indirectly, through the real `AwardXP`/`GetXPTier`/`GetXP` functions. |
| `server/entities.lua` | Resolving a network ID into a real entity safely — rejecting bad IDs, checking the entity still exists, and checking it's the expected type when asked. Also resolving which connected player owns a given ped. | Directly — both are file-level globals. |
| `server/notify.lua` | The shared `NotifyPlayer` function across its different call shapes, and that two other files' own local wrappers around it correctly forward to the real notification event. | Directly for the shared function; indirectly for the two wrappers. |
| `server/tenure.lua` | Partnership-tenure milestones — reaching a milestone at the right time, catching up on several missed milestones at once, never granting the same milestone twice (even across a simulated restart), and every condition that gates whether tenure ticks at all. | Indirectly, through the real background sweep loop, run against a fake in-memory database table. |
| `server/search.lua` | Picking the right "contraband alert" level for a given weight, including the boundary cases and a defensive check against a negative weight. | Directly, through a small test-only wrapper the file itself provides for this purpose. |
| `server/certifications.lua` | The core "is this player allowed to use K9 features" check, granting/revoking certification, revoking automatically on a job change, and the certification cache. This is the permission check almost every other feature in this resource depends on. | Directly for the plain functions; indirectly (through real event handlers) for the rest. |
| `server/kennel.lua` | Deploying, placing, cancelling, and picking up a kennel, plus cleanup when a player disconnects. | Directly, through the real event handlers, with the real cooldown and entity-resolution code loaded alongside it. |
| `server/combat.lua` | Bite-hold, takedown, and prop-dragging: the full request → confirm → end lifecycle, including a genuine mid-handler wait-then-recheck (so a target that moves away mid-check is caught for real, not simulated). Checks *what happened* (which event fired, to whom, with what data) rather than the exact wording of any notification, since this file's text was being rewritten to use `locale()` at the same time this test file was written. | Indirectly, through the real event handlers. |
| `server/fetch.lua` | The full throw/pickup/carry/drop/deliver/recall lifecycle for the fetch-ball feature, and that every failure case correctly tells the client to clean up rather than leaving an orphaned networked object behind. Also checks a rejected action never affects a different player's own fetch ball. | Indirectly, through the real event handlers. |
| `server/inventory.lua` | Three specific things: that only allowed items can go into a K9's gear stash, that the stash-protection hook can't accidentally end up registered twice, and that a bad config value for who can access a K9's gear fails loudly at startup instead of silently allowing too much access. | Indirectly, through real startup handlers and a fake `ox_inventory`. |
| `server/propattachment.lua` | Attaching/removing a prop to a K9 (e.g. a vest), including that every rejection tells the client to clean up the object it already created, and that the feature can be fully turned off by config. | Indirectly, through the real event handlers. |
| `server/wellbeing.lua` | Petting/feeding a K9 (and that pet+feed share one cooldown, not two separate ones), the periodic wellbeing "tick", what survives a disconnect versus what resets, and the cap that forces a K9 out of a stressed state after continuous danger. | Indirectly, through real callback and event handlers. |
| `client/main.lua` | Whether a model counts as a K9, the "can this player use K9 features right now" check (including its short-term cache), and the client-side bark sound/network-entity helpers. This is currently the only client-side file with test coverage — see "What's NOT covered" for why. | Directly for the plain functions; indirectly for the one event handler. |
| `server/exports.lua` + `client/exports.lua` | Every export this resource offers to other resources (9 server-side, 18 client-side): that each one works correctly, that the exact right number of exports gets registered, and that each one's safety checks (bad argument types, a missing dependency, an unexpected error) behave as documented. | Directly — every export tested is the real, registered one. |

**The table above predates several of the 41 files listed below** (e.g.
`recall`, `highcommand`, `permissions`, `integrations`, `tablet`, `breed`,
`defense`, `vehiclecombatguard`, and every `client*` spec besides
`client/main.lua` have no row here) — flagged rather than silently left
looking complete; whoever next touches this file should extend the table
to match, not assume the list above is exhaustive.

## The numbers below expire — here's how to re-check them

This folder has **41 spec files** as of 2026-08-25 (counted directly by
listing `tests/*_spec.lua`, not by trusting an earlier version of this
document — a prior version of this file said 17, which is far out of date).
This document's earlier per-file, per-test breakdown (698 individual tests
across 17 files) predates most of the files that exist today and is **not
reproduced here** rather than left stale, since this pass had no shell/git
access and could not run `./run.sh` to regenerate it. Treat any test count
in this document as **probably stale by the time you read it** — several
people work on this codebase at once and new spec files get added often —
and re-run the suite yourself before repeating a number from here to anyone
else.

Files present as of this pass (41): `cooldowns`, `exports`, `defense`,
`recall`, `mainserver`, `admin`, `tenure`, `inventory`, `certifications`,
`clientmovement`, `clientagility`, `clientvision`, `partnership`,
`vehiclecombatguard`, `propattachment`, `clienttracking`, `notify`,
`combat`, `clientradial`, `clientsearch`, `bonetool`, `clientaudio`,
`clienthud`, `clientscreenfx`, `clientprogression`, `clientproximityaudio`,
`entities`, `medkit`, `kennel`, `progression`, `wellbeing`,
`clientwellbeing`, `fetch`, `search`, `highcommand`, `permissions`,
`integrations`, `clienttablet`, `clientcombat`, `main`, `clientbreed`
(each suffixed `_spec.lua`).

**Whoever next has shell access should run `cd qbx_k9unit/tests && ./run.sh`,
add up each spec file's own `N passed, M failed` line by hand (`run.sh`
itself only prints an overall pass/fail verdict, not one combined number),
and replace this section with the real current commit hash, file count, and
test total** — the same way earlier versions of this section did.

### Why you can't just search for `t.test(` and count instead

It's tempting to search the spec files for the text `t.test(` and count the matches, instead of actually running the suite. Don't — it can undercount badly. For example, `exports_spec.lua` has one loop that runs 4 `t.test(...)` lines once for each of 13 exports. That's 4 lines of source code, but 52 real test cases at runtime (4 × 13). A text search would only find the 4 lines. The only trustworthy source for a test count is actually running `./run.sh` and reading what it prints.

### `ClampLimit`'s odd-number tests, specifically

`ClampLimit` (in `server/admin.lua`) turns a user-supplied limit into a safe number for a SQL `LIMIT` clause. A code review flagged that a strange input — `NaN`, infinity, a huge number like `1e400`, a negative number — could theoretically make it crash. `admin_spec.lua` locks in exactly what happens today for each of those inputs, run through the real command handler, so if a future change to this Lua build ever makes one of them behave differently, the test will fail loudly instead of the bug reappearing silently.

## What's NOT covered, and why

- **Almost all client-side code (`client/*.lua`) is untested**, except for `client/main.lua` (see the table above). Every other client file calls real client-only game functions (moving the camera, disabling controls, reading ped positions, sending data to the UI) that have no server-side equivalent to fake convincingly, and several also depend on a live player-data cache that only exists in a real game session. This is a real gap, not an oversight — it would take a much larger effort than building the sandboxes used for server code.
- **`server/tenure.lua`'s "avoid re-running a database check" cache doesn't actually avoid it.** The test file itself proves that a certain database check runs on every tick regardless of this cache, because the cache can only be checked *after* that same database call already ran once. This is a minor, ongoing cost (one extra database read per online, fully-progressed K9 partnership per tick) — not a correctness bug. The actual protection against double-granting a reward is a separate, database-level check, which the same test confirms works.
- **Nothing here talks to a real database, `ox_inventory`, or `ox_lib`.** Every test fakes those boundaries and checks what the production code does with a fake response (what query it would run, what it does with a given answer) — never whether a real database would actually accept that query.
- **`server/cooldowns.lua`'s background sweep** is tested for picking the right entries to remove, but not for real-world timing accuracy — waiting is faked instantly in tests, on purpose, so the test suite doesn't take real time to run.

## Adding a new spec

1. In your new spec file, load the two shared helpers: `dofile('testkit.lua')` and `dofile('fixtures/sandbox.lua')`.
2. Build a small table of stand-ins (stubs) for exactly the FiveM functions your target file actually calls. Start with an empty table — running `lua5.4 yourspec.lua` will tell you the name of the first thing you're missing.
3. Call `Sandbox.newEnv({...})` with your stubs, then `Sandbox.loadInto('../server/whatever.lua', env)`. If that file depends on another real file (e.g. `server/cooldowns.lua`), load that one into the same sandbox first, in the same order `fxmanifest.lua` already lists them.
4. Drive the file through its real functions or real event/command handlers, and check the real, observable result (a fired event, a printed line, a notification) — never a rewritten copy of the logic you're testing. If you're checking notification text, build the expected text with `Sandbox.locale(...)` rather than typing the English sentence in by hand (see "`locale()` inside the sandbox is real" above).
5. End the file with `os.exit(t.summary())`.
6. Never change the production file just to make it easier to test. If something genuinely can't be reached, write that down in "What's NOT covered" above instead of working around it.
7. **If you're updating the numbers in this README after adding a spec:** replace the whole "numbers below expire" section together — new commit hash, new timestamp, new counts, all from one fresh `git rev-parse HEAD` / `git log -1` / `./run.sh` run. Never hand-edit just the total while leaving the old commit hash in place; a number with a stale, mismatched commit hash looks trustworthy when it isn't, which is worse than an honestly-labeled old number.
