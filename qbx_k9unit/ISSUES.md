# Issues

**This is the one place issues live.** Anything found — a bug, a limitation,
a decision waiting on you — goes here and nowhere else. If it is not in this
file, it is not tracked.

Last updated: 2026-08-26 (watchdog pass; nothing new waiting on you)

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

### Decided: fix the text-encoding mismatch — DONE

Being done in two halves, deliberately:

- **New installs are fixed properly.** Every table now states its encoding
  explicitly instead of inheriting whatever the server happened to default
  to. Free, and it makes the result the same on every machine.
- **Your existing database gets an optional extra**, not a forced upgrade.
  Converting live tables rewrites them completely, and the search log is
  designed to grow into the millions of rows — so it would be the slowest
  thing this resource has ever asked you to run, for a papercut that never
  affects the script itself. It ships in `sql/migrations/optional/` — a
  separate folder, deliberately outside the automatic sequence, so it
  cannot be run by accident during a routine upgrade. Run it when you
  choose, or never; there is also a one-word workaround if you would rather
  not.

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
| Scent tracking on qb-inventory | **The one to know about.** If you run `qb-inventory` rather than `ox_inventory`, the K9 will not pick up scent from items dropped on the ground. Everything else about tracking works. This one is called out separately because of HOW it fails: the connection reports success and then quietly does nothing, because qb-inventory never announces a ground drop at all. Nothing appears in your console. |
| Vehicle search on qb-inventory | Searching a vehicle always comes back empty on `qb-inventory`. Searching a person still works. This one does report a failure rather than pretending. |
| Inventories we cannot support | Five of the eight inventories in the compat list are paid scripts with no readable source. They are listed but stay inert, and say why in the console rather than pretending. Confirming one needs a live install, not more searching. |
| Tenure database check | Runs one small indexed query every five minutes per fully-tenured pair rather than skipping it. Deliberate, documented and tested — do not "fix" it. |

---

## 3. Still being built

Not issues — work in flight. Listed so nothing looks finished that is not.

**Document consolidation is now FINISHED.** Twenty markdown files down to
nine. Everything technical lives in one `DEVELOPER_REFERENCE.md`; what is
left besides it is the licence, the changelog, this file, the ideas list,
the audio credits, and the three you actually read — README, player guide,
operator runbook.

**Works with any ped is now FINISHED.** Verified, not assumed: a certified
handler on a human body — or any custom ped — can leash, partner, carry,
be treated and be attached to. 343 tests across the five affected files,
including one that pins the half that matters more: widening the role check
did NOT weaken the access check. A role-holder still has to be certified.
Jump and crouch are deliberately kept, per your decision above.

**Running without a database is now FINISHED.** `Config.Database = false`
genuinely stops all SQL — verified, zero direct database calls remain
outside the one accessor layer, and exactly one place in the entire
resource reads that setting. Everything still works; it simply forgets
everything on restart, and writes no audit trail.

*One caveat that is not obvious: you still need `oxmysql` installed as a
resource. FiveM refuses to start this script without it, and that check
happens before your config is ever read. "No SQL" means you never import
our tables — not that you can remove oxmysql.*




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
- **A note that named no owner sat unactioned.** A documentation pass
  found that `fxmanifest.lua` described a dev tool as ACE-gated when it had
  stopped being ACE-gated, wrote "needs correcting by whoever owns that
  file", and moved on. Nobody owned it, so nobody did. Anyone auditing who
  can run that tool would have read the wrong answer off the manifest.
  *Rule: the pass that finds a problem either fixes it or writes it in this
  file — "someone should" is not a handoff.*
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
