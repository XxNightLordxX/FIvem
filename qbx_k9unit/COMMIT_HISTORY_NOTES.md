# Commit history: correction record

**Read this if you are trying to work out which commit did what.**

Thirty commits on `claude/code-improver-subagent-qlt3bn`, from `da2fe174` to
`93395216`, were audited line by line against their own diffs and against the
current state of the code. Eighteen of the thirty describe their own work
inaccurately.

Nothing is missing and nothing is broken. Every feature described in those
messages exists in the tree and works. What is wrong is the *record* — which
commit gets credit for which change.

## What happened

The work was done by roughly twenty agents editing one shared checkout at the
same time. Commits were made with a blanket `git add -A`, which stages
everything in the working tree — including whatever other agents happened to
have half-finished at that moment. So a commit intended to carry one change
carried several, and its message described only the one.

This is my error, not the concurrency's. It was pointed out, acknowledged, and
then repeated. Two commits made after I said I had fixed the practice —
`7752daf` and `a383b6a` — carry work their messages do not mention, for the same
reason.

Staging an explicit list of files was not enough, and it took three more
commits to work out why. Agents were told to verify their own work by staging
their files and building a tree from the index — so they were writing to the
same index I was committing from. Between my checking what was staged and my
committing it, an agent could add its own files, and did.

The practice that actually works, now in use: keep a private index
(`GIT_INDEX_FILE` pointing at a scratch file), stage into that, build the
verification tree from that, and commit from that. No other process can reach
it. Then read the file list one final time and reconcile it against what the
message is about to claim.

## Was anything pushed in a broken state?

No, and this was checked rather than reasoned about. Each of the thirty commits
was extracted into a clean tree and linted: **all thirty are clean, 0 warnings
and 0 errors.** Every commit that actually carries a change carries it whole —
production code, its manifest and locale companions, and its own tests, together
in the one commit — and always *earlier* than the commit that later claims it.
There is no point in the history where the branch would have failed to load.

The one exception is prose, not code: `5bb63e676` says the Shop Items screen
"landed" one commit before `bd71a0975` actually adds it.

## The table

**A** — accurate.
**B** — the headline is true, but the commit silently carries other real work, or
omits a caveat the code itself discloses.
**M** — the message describes work that is not in that commit's diff. "Landed at"
names where it really is.

| SHA | Subject | | Note |
|---|---|---|---|
| `da2fe174` | Let high command block the twelve client-only features per person | A | Wires 9 of 12 and does not overclaim the rest |
| `a259b1e5` | Add wording for a block that is real but weaker than server-enforced | A | |
| `c96629cb` | Close seven server-side per-person block gaps | A | Prose names six but says seven |
| `edadce94` | Stop teleport-biting, and stop biting people sitting in cars | A | |
| `254b47ef` | Assign tiers, renew and specialize from the tablet, on offline people too | A | |
| `0404ed56` | Stop the tablet string test crying wolf on correct work | A | |
| `2857d4ea` | Add live permission-key and XP-rank catalogs | B | Silently ships the whole feature-block push in `server/permissions.lua` |
| `63f24839` | Deliver per-person blocks to the client | M | The push half is not here. Landed at `2857d4ea`. The client listener genuinely is here |
| `5a0d1d9f` | Land eight parallel workstreams | B | Silently adds the two missing `sql/install.sql` tables and the theme-push fix |
| `9e8f141d` | Stop reporting partial database writes as success, and fix the theme push | B | Also carries scent-hunt, appearance, fetch and SAR fixes; re-describes the theme fix `5a0d1d9f` already made |
| `25fb2ff7` | Close a retry-window bypass in the anti-teleport check | B | Named claim verified genuinely closed; also carries a scent-hunt sweep and an appearance write-check |
| `1917cfff` | Add equipment shop denial messages | B | A real fix in `client/proximityaudio.lua` described as "spec and fixture work" |
| `c617165a` | Add two tables a fresh install would never have created | M | Landed at `5a0d1d9f`. This diff instead carries the shop-hook fail-closed fix, unmentioned |
| `b58fdbde` | Fix a broken test fixture and three assertions that could not fail | M | The fixture repair landed at `1917cfff` |
| `5bb63e67` | Stop the tablet telling operators a working feature does nothing | B | Main claim accurate; "the Shop Items screen landed" is a forward reference |
| `bd71a097` | Stop a revoked handler's scent hunt from locking them out permanently | M+B | Landed at `9e8f141d` and `25fb2ff7`. This diff silently ships the 630-line Shop Items screen |
| `f15f44ee` | Correct fourteen config comments | B | Silently ships `WaitForSchemaCheckToSettle()` and the self-promotion accounting |
| `8db1de60` | Close six client-side leaks and traps | M | All six landed earlier, across five commits. Zero overlap with this diff |
| `1fa8db20` | Make a staff self-promotion visible | M | Landed at `f15f44ee` |
| `7e9b4b4f` | Build the Shop Items screen | M+B | Landed at `bd71a097`. This diff instead carries the medkit cooldown fresh-read and a permission-key grant capability |
| `53e366de` | Make the shop hooks deny on error | M | Landed at `c617165a`. This diff is one test file |
| `448024fc` | Close the schema-collision boot race, and stop appearance writes claiming success | M | All four claims landed at `f15f44ee`, `25fb2ff7`, `9e8f141d`, `7e9b4b4f`. This diff is one test file |
| `3dd62a93` | Fold in the tablet server spec updates | A | |
| `278d89b8` | Let a retired permission be revoked, keep the shop alive across a toggle | A | |
| `49416ee3` | Watchdog: first recorded pass | A | |
| `cf47c677` | Land the certification and tier-catalog work that is finished | A | |
| `be230bec` | Unblock two in-flight agents | A | |
| `3ba31f32` | Carry sprint momentum through a vault | A | |
| `ffb405f6` | Make the speed boost and stamina numbers genuinely editable | B | Claim verified end to end; also carries an unrelated 289-line spec addition |
| `93395216` | Add the Commands page, close a partnership XP farm, and stop reset lying | B | See the two overstatements below. Also silently ships the per-K9 override system and a Home/branding overhaul |

**12 accurate, 9 partial, 9 mis-credited.**

Three later commits carry the same fault and are recorded here for
completeness:

- `7752daf` — message covers the licence, offline names and the issues list; also
  carries the ped third-eye icon pass, `server/k9profiles.lua` changes and two
  test fixes.
- `a383b6a` — message covers the tablet string sync; also carries the whole
  world-object third-eye pass.
- `e23d198` — message covers five pieces of work by name; also carries the
  name-resolution pass (`server/tablet.lua` and two specs), which resolves the
  granting officer's citizenid to a real character name across the audit trail
  and certification rows. That commit was made after this file first described
  the problem, which is what finally identified the shared-index cause above.

## Two claims that were overstated

**"The Commands page cannot go stale."** It can. The drift guard compares
registered commands against the page, but only across a hand-maintained list of
filenames. A new file that registers a command and is not added to that list
drifts silently. That gap was real and has since been closed for
`client/keybinds.lua`; the mechanism still depends on someone maintaining the
list.

**The partnership XP farm is "closed".** The fix is real, but it is held in
memory only. A resource restart clears it, which re-opens the exploit once, for a
pair that breaks up around that restart. The code says this at length; the commit
message did not.

## What this record is not

I am not rewriting the history to tidy it up. These commits are pushed, and
quietly rewriting published work to make the record look better would be a worse
thing than the original mistake. The table above is the correction.
