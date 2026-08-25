# Issues

**This is the one place issues live.** Anything found — a bug, a limitation,
a decision waiting on you — goes here and nowhere else. If it is not in this
file, it is not tracked.

Last updated: 2026-08-25

---

## 1. Waiting on you

Four things need a decision only you can make. Nothing is broken while they
sit here; each is a choice about how you want the server to behave. Every
one is a small change once you have decided.

### 1.1 Should a K9 on a human body lose jump and crouch?

You asked for everything to work with any ped, including a human one. Two
places restrict what a K9 can do *because* a dog cannot do it: jumping and
crouching are suppressed, and an injured K9 has sprinting and jumping
blocked.

If we apply those to a human-shaped K9 as well, they lose jump and crouch
they never had a reason to lose. If we do not, a human-shaped K9 has
slightly more movement than a dog-shaped one.

Neither is wrong. It is taste. **Recommendation: leave the restrictions off
for a human body** — the restrictions exist because of the animal's shape,
so applying them to a human is a rule copied past its reason.

### 1.2 Who should see the roster?

Right now any certified K9 handler can open the tablet's roster and look up
any citizen ID, which shows that person's certification history, their XP,
and **which people hold the high-value permissions** (who can certify, who
can audit, who can grant XP).

Nobody can *change* anything this way — it is read-only. But a rank-and-file
handler can work out who the powerful people are, department-wide.

**Recommendation: restrict looking up other people to high command**, and
leave every handler able to see their own record. Say the word and it moves.

### 1.3 Database text encoding

Our tables and qbx_core's tables use slightly different text-sorting rules.
It never affects the script — everything here works. It only bites if *you*
write your own SQL report joining our tables to the player table, which
errors until you add one extra word to the query.

Fixing it for **new** installs is free. Fixing it for **your existing**
database means rewriting every table, which on your biggest table is slow
and needs a quiet moment.

**Recommendation: fix it going forward only.** Existing installs stay as
they are unless you specifically want it, in which case it ships as an
optional extra you run when you choose.

### 1.4 Keep a copy of the ox libraries

Not a bug — insurance. This resource needs `ox_lib`, `ox_target`,
`oxmysql` and `ox_inventory` to start at all. Those went unmaintained for
about a year (April 2025 to April 2026) before the original team came back.
They are active now — last commit checked was eight days ago.

**Recommendation: save a copy of the versions you currently run** to a
backup folder, so a repeat of that quiet year cannot strand you. No code
change; purely something to keep somewhere safe.

*Reassess only if one of those four repositories is archived again, or six
months pass with no commits. Not before.*

---

## 2. Known limitations

Things that work as designed but have an edge you should know about. None
need action.

| What | The edge |
|---|---|
| Search-and-rescue reveal | The "you found them" figure is visible only to the officer who found it, not to others nearby. Deliberate — it avoids a whole class of ghost-entity bug. |
| Pursuit sprint cooldown | Resets if a player disconnects and reconnects. It is a movement burst, not XP, and reconnecting mid-chase costs them the chase anyway. |
| Find alerts on trails | Covered — the reaction no longer depends on the XP system being switched on. |
| Partnership survives disconnect | On purpose. Partnerships are meant to last across a shift; leashes are not. |
| Audio near clustered K9s | Several K9s standing together each track the others, so the cost grows faster than the number of dogs. Fine at normal play; the thing to watch if resmon ever creeps. |
| Tenure database check | Runs one small indexed query every five minutes per fully-tenured pair rather than skipping it. Deliberate, documented and tested — do not "fix" it. |
| One inventory hook unverified | The contraband-drop hook is written against `ox_inventory`'s documented shape but has never been run against a live install. It is wrapped so a mismatch logs a line rather than breaking anything. |

---

## 3. Still being built

Not issues — work in flight. Listed so nothing looks finished that is not.

- **Running without a database.** `Config.Database = false` is wired through
  most of the resource but not all of it yet. Until it is finished, that
  setting does not fully do what it says.
- **Works with any ped.** Most of the way there. A few places still check
  the dog *model* instead of the K9 *role*, so a certified handler on a
  human body cannot yet leash, partner, carry, or be treated.
- **Document consolidation.** Twenty files down to about seven.
- **Connecting the compat adapters.** The translation layer for other
  targeting and inventory scripts is written but not yet called, so today
  everything still goes through `ox_target` and `ox_inventory` directly.

---

## 4. Fixed, and worth remembering

Kept short deliberately — these are here because each one taught a rule
that stops it recurring, not as a changelog.

- **Five separate files were written, tested, and never registered** in
  `fxmanifest.lua`, so they silently never loaded. Nothing in the toolchain
  catches this: the linter passes, the syntax check passes, and the feature
  simply is not there. *Rule: a file and its manifest entry land in the same
  change.*
- **Setting any cooldown to `0` killed an entire file at startup**, taking
  three features and the function that ends a hold down with it — which
  strands players mid-action. Zero means "no cooldown" in most other
  scripts, so it was the most likely thing an operator would type. *Rule: a
  misconfiguration gets a loud warning and a safe default, never an abort.*
- **Decertifying someone mid-incident left their dog still holding the
  suspect** for up to twenty seconds. Leash and partnership were both
  severed on revoke; the hold was not. *Rule: if something must not outlive
  a certification, check the whole family, not the two you thought of.*
- **The uninstall script refused to run, every time**, on a one-character
  shell quoting bug. Backups still ran, so nothing was ever at risk — but
  the safe path could not work.
- **A test asserted a bug was correct behaviour.** The find-alert/XP
  coupling had a spec pinning it in place. *Rule: when a test defends
  surprising behaviour, check the behaviour before trusting the test.*
- **Nine test files broke while the code was right.** Moving a function to a
  new file leaves the game working — the manifest loads it — but breaks
  sandboxes that load production files directly. *Rule: moving a function is
  not done until every spec that loads a caller also loads its new home.*
- **A dependency was reported dead that was not.** Two archive banners on a
  fork led to the wrong conclusion about the real project. *Rule: read the
  repository the manifest actually names, and take dates from the feed, not
  the rendered page.*

---

## How to use this file

If you hit something odd, add a line under **Waiting on you** in your own
words — where you were, what you expected, what happened. It does not need
to be technical to be useful; "the dog wouldn't get in the car at the
Sandy Shores station" is a better bug report than most.
