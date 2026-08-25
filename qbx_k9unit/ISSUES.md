# Issues

**This is the one place issues live.** Anything found — a bug, a limitation,
a decision waiting on you — goes here and nowhere else. If it is not in this
file, it is not tracked.

Last updated: 2026-08-25 (all four open decisions answered)

---

## 1. Waiting on you

**Nothing.** All four open decisions were answered on 2026-08-25 and are
recorded below with what was done about each. New items go here as they
come up.

### Decided: a K9 on a human body keeps jump and crouch — DONE

You said it should not lose them, and it no longer does. Both restrictions
— jump/crouch suppression, and the injured-K9 sprint/jump block — now check
the *body*, not the role. The reasoning is written into both files so a
future "make everything work with any ped" sweep does not helpfully undo
it: these restrictions exist because a four-legged animal has no jump
animation, so applying them to a human-shaped handler is a rule copied past
its own reason.

### Decided: roster lookups restricted to high command — DONE

Looking up another person's record now requires high command, **or** an
explicit `k9.audit` grant. Ordinary certification no longer gets you in.

Keeping `k9.audit` is not a loophole in "restrict it to high command": that
capability is granted *by* high command, to one named person, for exactly
this purpose — dropping it would leave a permission that is defined,
grantable, documented, and does nothing. What actually closed is the path
where simply being a certified handler let you enumerate who holds the
powerful permissions department-wide. That was never a decision anyone
made; it was a side effect of asking "do they have *any* permission at
all".

Unchanged: every handler can still see **their own** record. That is a
different question from looking up someone else.

### Decided: fix the text-encoding mismatch — IN PROGRESS

Being done in two halves, deliberately:

- **New installs are fixed properly.** Every table now states its encoding
  explicitly instead of inheriting whatever the server happened to default
  to. Free, and it makes the result the same on every machine.
- **Your existing database gets an optional extra**, not a forced upgrade.
  Converting live tables rewrites them completely, and the search log is
  designed to grow into the millions of rows — so it would be the slowest
  thing this resource has ever asked you to run, for a papercut that never
  affects the script itself. It ships clearly labelled, with honest timing,
  to run when you choose. There is also a one-word workaround if you would
  rather not run it at all.

### Decided: keep a copy of the ox libraries — YOUR ACTION, not code

Save a copy of the `ox_lib`, `ox_target`, `oxmysql` and `ox_inventory`
versions you currently run into a backup folder. They went unmaintained for
about a year before the original team returned; they are active now. This
is insurance against a repeat, not a fix for anything broken. Nothing in
the code changes.

*Reassess only if one of those four is archived again, or six months pass
with no commits. Not before.*

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
