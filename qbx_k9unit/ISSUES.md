# Issues

**This is the one place issues live.** Anything found — a bug, a limitation,
a decision waiting on you — goes here and nowhere else. If it is not in this
file, it is not tracked.

Last updated: 2026-08-26 (five things need you — section 1)

---

## 1. Waiting on you

Two things genuinely need you rather than more code. Both are about
features that are **switched on in the config you'd ship today**, so they
are not hypothetical.

Everything below the horizontal rule is a decision already made — kept for
the record, not asking anything of you.

### Decide: is the bite/takedown trust boundary good enough? — NEEDS A LIVE TEST

Three features (bite and hold, non-lethal takedown, and dragging) are
protected against a player running a modified game client by a guard that
checks where the instruction came from. The guard is written, reviewed and
believed correct. **Nobody has ever attacked it on a running server**, which
is the only way to actually know.

`OPERATOR_RUNBOOK.md` §3 describes the test. It needs a live server and
someone willing to try to break it — no amount of further code reading
settles it. All three features are `true` in the shipped config.

Your options: run the test, accept the risk as-is, or switch those three
off until it's been done.

### Decide: the fear/stress griefing tradeoff — POLICY, NOT CODE

`FearStressSystem` is on by default, and there is a way for a player to
repeatedly wind up someone else's dog. It can be made *harder* but not
eliminated, because the mechanic's whole point is that the dog reacts to
what happens around it — a dog that can't be upset isn't the feature.

This is a call about your server's players, not a bug: some servers want
the emergent chaos, others don't. Leave it on, switch it off, or ask for
the cooldowns to be tightened.

### Decide: "works with any inventory/dispatch/framework" — one of those three is not true

Auto-detection genuinely works for **inventory** and **targeting**. Those are
threaded through the whole resource: change your inventory script and this
adapts.

**Framework is different, and the honest answer is that it does not work.**
There are well-researched adapters for qb-core and ESX, but only one file in
the entire resource actually uses them — everything else (certifications,
permissions, the tablet, XP, combat: about 169 places) calls Qbox directly.
Qbox is also a hard requirement in the manifest, so the resource will not
even start without it. If you run qb-core or ESX, detection will correctly
identify it and the resource will still not work.

Two honest options: **say so plainly** in the docs and config — cheap, and
what I'd suggest unless you actually need this — or **commit to converting
those ~169 call sites**, which is a large job, not a quick fix.

There is a smaller version of the same thing: the **ambulance/downed**
detection is built and researched but nothing calls it yet, so "detect
whether someone is down" still falls back to a guess unless you set the
manual override. That one is a small, scoped fix and is being written now.

### Decide: certification tier permissions currently change nothing

High command can add tiers, edit them, reorder them and tick capability
boxes per tier — that all works and is tested. But **nothing in the game
reads those capability ticks yet.** Changing what a tier is allowed to do
changes the checkboxes and nothing else.

This is disclosed in the code, not hidden, but it means the "edit permissions
for those roles" half of what you asked for is a working control panel wired
to nothing. Worth deciding whether you want the capabilities to actually gate
things, and if so which ones.

### Confirm: "any ped" has two more exceptions than the two you decided

You decided a K9 on a human body keeps jump and crouch. Two other things are
also decided by the body rather than the role, and only one carries a note
saying you agreed to it:

- **Sprint is also blocked when injured**, on the same body-not-role basis.
  Recorded as the same decision extended by the same reasoning — sensible,
  but you did not explicitly say it.
- **The whole speed system** — breed speed and the fatigue slowdown — only
  applies on a dog body. So a role-holder on a human body gets no fatigue
  penalty at all. This one is structural rather than a decision anyone made.

Neither is hidden, but if "everything works with any ped" was meant
literally, the second one is a real gap. Say the word and it gets fixed.

### Checked and NOT a risk: the bone sweep dev tool

Raised as a concern, so recording the answer here to stop it being raised
again. `Config.Features.BoneSweepDevTool` is `true` in the shipped config,
and its own comment says never to enable it on a production server — which
reads alarming. It is fine, because that flag alone does nothing.

The command is only registered if the flag is on **and** you have explicitly
set `qbx_k9unit_enable_bone_dev_tool 1` in your server config. That convar
defaults to `0`. If you have never heard of it, the tool is not running on
your server.

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
| Audio near clustered K9s | **This row was wrong until 2026-08-26 and is now corrected.** It claimed the cost grows faster than the number of dogs. It does not. Each player's own game independently tracks the K9s within about 25m of them, and that cost is linear in the dogs near *them* — the periodic scan behind it costs the same whether there is one dog or ten. A big cluster of dogs *and* players multiplies the total across the whole server, but no single player ever pays that sum, and real handler counts are nowhere near high enough for it to matter. Nothing to watch. |
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
- **Two "permanent limitations" were neither.** Both qb-inventory gaps —
  scent tracking never firing, and vehicle search always coming back empty —
  were written up as things the backend simply could not do. Re-reading
  qb-inventory's actual source found the drop hook the earlier pass said did
  not exist, and found that vehicle trunks just use a different id format
  than the one being asked for. Both now work. The earlier research had also
  miscounted that project's own file list, which is likely how the real code
  got missed. *Rule: "this is impossible" is a claim about someone's reading,
  not about the other project — re-read the source before writing it down as
  permanent.*
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
