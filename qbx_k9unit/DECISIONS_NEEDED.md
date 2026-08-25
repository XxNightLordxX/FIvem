# qbx_k9unit — Status & Decisions Needed

Written 2026-08-24, rewritten the same day after roughly 15 more commits
landed on top of the first draft. Covers the whole resource as it stands
right now, and lists the calls that are genuinely yours to make rather than
ours. If you only read one document in this repo before deciding anything,
read this one — everything else is detail underneath it.

Nothing here is urgent in the "production is broken" sense. **Every feature
built this session still ships `false` by default**, and the five Phase 1
features that ship `true` have been re-verified conformant repeatedly. The
decisions below gate whether any of the rest ever gets switched on.

Two other groups are looking at this resource in parallel right now (config
tuning and release/security readiness). Their findings aren't in yet, so a
couple of items below (D4, D5, D6) may pick up more detail shortly — treat
this document as current as of today, not as the last word on numeric
tuning.

---

## 1. Where the resource actually stands

**48 Lua files on disk, every one of them loaded.** `config.lua` is the one
shared script; the other 46 resource files are split across
`fxmanifest.lua`'s `client_scripts`/`server_scripts` lists exactly as
written, with nothing orphaned and nothing missing. That's new since the
first draft of this document — at that point several finished files
(exports, the admin/audit surface, the tenure bonus, the NUI audio bridge,
the contraband screen effect) existed on disk but weren't wired in. That gap
is closed. Lint and syntax are at a genuine zero across the resource, and CI
runs both on every push.

**Forty `Config.Features` flags exist; five are on.** (An earlier draft of
this document said "thirty-one" — that was already stale when written and
is more so now; forty is a fresh count against today's `config.lua`.)

**Live today** (`true` by default): leash mechanics, radial menu, vehicle
entry/exit, basic bark, basic jump/crouch.

**Built, reviewed, and reachable in-game, shipping `false`**: scent/blood/
gunpowder tracking, contraband search + audit log, thermal/night vision,
door scratch and nudge, bite-and-hold, non-lethal takedown, prop dragging,
advanced agility vault, handler-down defense, handler partnership registry,
Recall, K9 inventory stash, medkit, XP progression, the five-stat wellbeing
system, health/stamina HUD, deployable kennel, advanced bark radial, prop
attachments, the fetch mechanic, proximity audio, the contraband screen
effect, the admin/audit surface, and partnership-tenure bonuses.

**New since the first draft of this document, one line each:**

- **Recall** (`/k9recall`, `server/recall.lua` + `client/recall.lua`) — the
  handler's "call the dog off" button, ending whatever bite/takedown/drag
  their partnered K9 currently holds. Deliberately never blocked by
  certification state, by design — see D2's "no unbounded trap" rule.
- **Prop attachments** — a cosmetic vest/harness the K9 can toggle on
  itself. Code-complete; the attach point is a placeholder until D8 below is
  done.
- **Fetch** — throw a ball, the K9 fetches it, the handler collects it back
  manually (nothing here scripts a player's movement). Ships in a safe
  "delete and re-appear" mode rather than a real mouth-carry, pending D8.
- **Proximity audio** — ambient K9 sound that fades with listener distance,
  built on the same silent-until-supplied audio bridge as bark sounds. See
  D7.
- **The contraband screen effect** — a brief screen effect for the
  *searching* K9's own handler (never the person being searched) when a
  search turns up a large stash. One historical documentation bug about this
  feature is worth knowing about — see §6.
- **The admin/audit surface** (`/k9auditcert`, `/k9auditpartner`,
  `/k9auditsearch`) — read-only, ACE-gated commands over the certification,
  partnership, and search-log tables, so an admin no longer has to run raw
  SQL by hand. Zero mutation paths.
- **Partnership-tenure bonuses** — a one-time flat XP reward (15/40/100 XP)
  when a handler-K9 partnership stays continuously active for 1, 7, and 30
  days. Needs both `HandlerPartnership` and `XPProgression` on to do
  anything.
- **SQL migrations** (`sql/migrations/0001`–`0003`) — for a database that
  already ran an older `install.sql`. A brand-new install only ever needs
  the current `sql/install.sql`, which already includes everything the
  migrations add.

**Researched and deliberately not built**: `CameraFeedPiP` — no native
exists to render a secondary camera into a NUI texture. There's an open
upstream CitizenFX issue requesting exactly that native. This one is closed
as impossible, not deferred.

---

## 2. Decisions that block enabling anything

### D1. Which features do you actually want on?

This is the big one and everything else is downstream of it. Forty feature
flags exist; five are on. We built to spec, but we don't know your server's
appetite — a K9 unit that can drag downed players and bite suspects is a
very different fit from one that tracks scent and searches trunks.

Suggest picking a first tranche to enable and playtest, rather than flipping
everything. The tracking/search set (`ScentTracking`, `BloodTracking`,
`GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`) is the lowest-risk
group — read-only, no player-vs-player state, and the most thoroughly
reviewed and re-reviewed of anything in this resource. Combat is the
highest-risk group, for reasons in D2.

**Caveat on `ScentTracking` specifically**: it needs a one-time live check
first, see D6.

### D2. Do Category B combat effects ship, knowing a modified client can ignore them?

Bite-and-hold, non-lethal takedown, and prop dragging split into two kinds
of effect. **Category A** (the attach in prop dragging) is server-applied
and holds against a hostile client. **Category B** (movement restriction,
forced ragdoll, damage bracket) is inherently local — it only means
anything if the *target's own client* executes it, and a modified client can
simply decline.

We shipped Category B under five guardrails, the important one being that
no server-authoritative consequence is ever gated on a Category B signal
succeeding. Non-compliance is detected and logged, never punished
automatically — the config option for what happens on a detected violation
is hard-limited to `'log'` or `'notify_staff'`, never an automatic kick or
ban.

**Your call**: accept that a cheater can shrug off a bite hold, or keep
these three features off. There is no third option — this is a property of
how FiveM distributes entity authority, not something more code fixes. Most
servers accept it; we're flagging it rather than letting you discover it
from a player complaint.

### D3. The client-event origin check shipped resource-wide — still worth an in-engine confirmation before you lean on it for combat

A real exploit was found and fixed this session: a client-side event
handler couldn't originally tell a genuine server message from a local call
the player fired at themselves. Any player could loop one call for
indefinite invincibility — **with every feature switched off**, because
only the server checked the feature flags and that path never reached the
server.

The fix (`if source ~= 65535 then return end` at the top of each handler,
CitizenFX's own documented pattern) is now applied resource-wide — every
client-side event handler in every file carries it, not just the mechanic
where it was first found.

**But it's still graded medium-high confidence, not certain, and that
hasn't changed since the first draft of this document.** We confirmed from
primary source that the native behind a local `TriggerEvent` call takes no
origin parameter, and found the official pattern in CitizenFX's own docs —
but we could not reach the forums or trace the C++ path that populates
`source` on a real network receive, to independently confirm the
server-genuine case is reliably the number `65535` rather than, say, a
string. Nobody has run the five-minute empirical check yet (print `source`
and its type once from a real server trigger and once from a locally forged
one, and compare).

**The check has to test the right thing, and that changed on 2026-08-25.**
A dedicated review of `client/combat.lua` named a specific way this guard
could fail **open** rather than closed — which is the opposite of what the
rest of this section assumed, and the reason the experiment above is not
quite the right one.

If FiveM's client runtime treats `source` as an ordinary global that gets
set when a network event is dispatched and is simply *never cleared* for a
local `TriggerEvent`, then any client that has ever received a genuine
server event — which is every client, within seconds of connecting — is
carrying a stale `source == 65535`. A later self-triggered call would
inherit that stale value and **pass the guard**. The exploit this whole fix
exists to close would still work.

Nothing proves that is how it behaves. But it means the five-minute check
must compare the two cases **in sequence on one client**, not in isolation:
receive a genuine server event first, then fire a local one from the same
client, and see whether `source` still reads `65535`. Testing a local
trigger on a fresh client that has never received anything would come back
clean and tell you nothing.

**Your call**: trust it as shipped (it is strictly better than nothing, is
applied everywhere, and the per-mechanic feature gating closes the original
flags-off exploit independently of this guard), or run that sequenced check
on a dev server before enabling any combat feature. The more of Category B
combat (D2) you turn on, the more this one matters.

---

## 3. Resolved since the first draft — tune the numbers if you like

Two real defects were found in this session's economy audit. Both are now
fixed in code; what's left is a numbers question, not a decision that
blocks anything.

### D4. The XP tier scent bonus was dead — it's now a working multiplier. Tune the numbers if you want a bigger effect.

`Config.XPTiers` used to grant a flat `scentRange` per tier (5.0 / 6.5 / 8.0
/ 10.0 meters) applied as a floor against the tracking config's own
`maxRange` — which defaults to 40.0 for every track type. Since even the
Elite tier's value never exceeded 40, the bonus never did anything from the
day it shipped.

It's now `scentRangeMultiplier` — a multiplier over each track type's own
`maxRange` instead of a flat floor. Shipped values: 1.00 / 1.05 / 1.10 /
1.20 across the four tiers (Recruit through Elite), so an Elite K9 tracks
20% farther than a Recruit one. These are still placeholder balance numbers
— tune them freely in `Config.XPTiers` if you want a bigger or smaller
spread.

### D5. Contraband-search XP could be farmed — it's now capped to real police work. No action needed unless you want to retune it.

`searchContrabandFound` awards 25 XP whenever a search finds contraband,
originally limited only by a 10-second per-target cooldown. Since the
result is deterministic from real inventory contents, a handler could plant
contraband in their own trunk and re-search it every 10 seconds for roughly
9,000 XP/hour.

The fix: XP for a given search target is now only paid the first time
contraband is found there, and again only if that target's contraband
composition has genuinely changed since the last payout (a top-up, a
partial seizure, a full seizure-and-replant all count as "changed";
re-searching an untouched stash any number of times pays nothing further).
A real officer working a scene where contraband keeps changing keeps
earning normally; a farmer who never touches their own planted stash can't
re-earn from it. No action needed from you here — just noting it's closed,
in case you want to retune the 25 XP figure itself.

---

## 4. Decisions needing something only you can supply

### D6. Run the one-time `ox_inventory` check for scent tracking?

Scent tracking depends on `exports.ox_inventory:registerHook('swapItems',
...)`. The hook name and payload shape were confirmed by reading
`ox_inventory`'s own source directly (and, since the first draft of this
document, cross-checked a second time against its current live upstream
source, which matches exactly) — but never verified against a live install
you actually run. This has also been hardened since the first draft: the
hook now only registers if a runtime check confirms it actually exists on
your build of `ox_inventory`, and prints one clear warning and disables
scent tracking cleanly if it doesn't, rather than failing silently or
crashing the resource.

The recommended check is still logging the payload once on a dev server to
confirm field names before trusting it in production — a five-minute job,
now lower-stakes than when this was first written, but not yet done.
`Config.Features.ScentTracking` stays `false` until someone does this.

### D7. Supply bark audio, or accept silence?

Every bark in this resource — the Phase 1 generic bark and all three
`AdvancedBarkRadial` variants — is a placeholder soundset name that
resolves to a harmless no-op. The new proximity-audio feature uses the same
audio bridge and is silent for the same reason. **No audio files ship
anywhere in this resource.** We deliberately did not fabricate or download
any.

The cheaper path we identified is a small NUI audio bridge (built, wired
in, currently silent), which drops the requirement from "author RAGE
`.awc`/`dat151`/`dat54` audio banks" to "supply four short, genuinely Ogg
Vorbis `.ogg` files."

**This decision got sharper on 2026-08-25.** The leads were previously
unverified snippets and every audio host looked unreachable. Both turned out to
be tooling problems, not real ones — plain `curl` reaches all of them — so the
candidates have now been checked against each asset's own page or API. Full
table in `html/sounds/CREDITS.md`. Two headlines:

- **Nothing usable is public domain.** The Wikimedia files a previous note
  called "public domain" are **CC BY-SA 3.0/4.0**. The OpenGameArt file called
  "CC0" is **OGA-BY 3.0**. Kenney has no animal audio pack at all, and the
  Commons CC0 category has no genuine bark — its hits are the London place name
  "Barking" and spoken-word clips.
- **The OpenGameArt one is an active trap.** Searching that page for "CC0" does
  return a hit, because the file sits in a collection *named* "CC0 Audio". The
  licence field says OGA-BY 3.0. A quick text-search confirmation gets a false
  positive and ships an attribution-licensed asset as public domain — which is
  almost certainly how the original claim went wrong.

**Your call, now between three concrete options rather than an unknown:**

1. **Accept OGA-BY 3.0** — attribution only, no share-alike. Lightest real
   obligation, and the most likely fit. Files are `.wav` and need converting.
2. **Accept CC BY-SA** — attribution *plus share-alike*. Share-alike is the part
   worth pausing on: it is a copyleft term applied to audio you would ship
   inside a resource distributed to other server owners. Already `.ogg`.
3. **Commission or record your own**, or accept silence and drop
   `AdvancedBarkRadial`/`ProximityAudioFX` from your enable list.

Nothing was downloaded, because options 1 and 2 are licensing commitments about
your project and are not ours to make on your behalf.

### D8. Run the bone-index sweep — it now finishes two features that are otherwise shipped, rather than unblocking work that doesn't exist yet.

This was previously "run it, or leave both features unbuilt." That's no
longer accurate: `PropAttachments` and `FetchMechanic` are both fully built
and playable today, and a dev-only sweep tool now exists
(`client/bonetool.lua` + `server/bonetool.lua`, gated behind its own feature
flag *and* an ACE permission, never enable on a live server) to answer the
one remaining question — which numeric bone index on a dog skeleton is the
right attach point for a vest or a mouth-carried item.

Until someone runs it: the vest attaches at the root bone (index 0), which
is always valid and never crashes, but looks wrong. Fetch ships in a "delete
and re-appear" mode instead of a real mouth-carry, which is fully playable
but not as polished.

**Your call**: run the sweep (a bounded, ~20-line, one-session dev-server
test — the tool does the hard part) to get a correctly-placed vest and a
real mouth-carry, or leave both features as-is; neither is blocked or unsafe
without it, just less polished.

### D9. Confirm the kennel prop model?

`client/kennel.lua` ships `prop_doghouse_01` on a single unverified source,
with a documented fallback and a graceful failure path if the model never
loads. Worth eyeballing on a dev server before enabling
`DeployableKennel`. Low stakes — it degrades safely to an obviously-wrong
placeholder object rather than breaking anything.

---

## 5. Decisions about direction

### D10. Which complementary work, if any? — the top three are now built.

The first draft of this document, quoting `COMPLEMENTARY_FEATURES.md`,
recommended three things ranked by value-per-effort. All three are now
built:

1. **An export/event API surface** — done (`server/exports.lua` /
   `client/exports.lua`, 9 server exports, matching client-side display
   exports, and six outbound events for other resources to listen for).
   This was a real gap: the resource previously declared zero exports,
   which made it a hard blocker for any dispatch/MDT/evidence integration.
2. **An in-game admin/audit surface** — done (`/k9auditcert`,
   `/k9auditpartner`, `/k9auditsearch`), replacing "an admin runs raw SQL by
   hand" with three read-only, ACE-gated commands. No mutation path exists.
3. **Partnership-tenure bonuses** — done (see the "new since" list in §1).

`COMPLEMENTARY_FEATURES.md` has further ideas ranked below these three
(dispatch integration, MDT/evidence integration, deeper XP-tier unlocks, a
cooperative-search bonus, certification specializations) — none built, none
urgent, worth a read if you want to plan further ahead once D1's first
tranche is live.

Verified maintained: `ps-dispatch`, `ps-mdt` (real evidence exports),
`qbx_ambulancejob`/`qbx_medical`. Verified **dead**: `qbx_prison` is
explicitly "Not Maintained" — don't build against it. We could not confirm
canonical repos for `cd_dispatch`/`qs-dispatch` despite `config.lua` naming
them by convention.

### D11. Pin dependency versions? — ANSWERED, and the answer is "you can't"

**Do not attempt this.** Verified against the FiveM engine's own C++ source
(`ResourceDependencyLoader.cpp`, `ResourceManagerConstraintsComponent.cpp`,
`ServerResources.cpp`, read directly from a clone of `citizenfx/fivem`): the
`dependencies` block has **no version-constraint syntax at all**. A string
is only treated as a constraint if it begins with `/`, and the only
constraints the engine defines are `/server:BUILD`, `/onesync`,
`/gameBuild:BUILD`, and `/native:0xHASH`. Everything else is a literal
resource-name lookup.

So writing `'ox_inventory@2.47.9'` or `'ox_inventory >=2.47.9'` would not
pin anything — it would fail to resolve as a resource name and **hard-break
this resource's startup**. Corroborated against four live upstream
manifests (`ox_lib`, `ox_target`, `ox_inventory`, `qbx_core`), none of which
encodes a version in a dependency entry.

**What to do instead**, and this is the actual decision:

- A documentation-only "last verified compatible" note in the manifest,
  already in `README.md` and re-checked twice since the first draft with no
  drift found: `qbx_core` 1.24.0, `ox_lib` 3.39.0, `ox_target` 1.18.1,
  `oxmysql` 2.14.1, `ox_inventory` 2.47.9. Honest caveat: these are "newest
  version the assumptions were checked against," not proven minimums —
  nobody git-blamed how far back each API goes.
- A **runtime capability check** for `ox_inventory` specifically, the only
  dependency with version-sensitive behavior this resource relies on. This
  is now built (see D6) — the scent-tracking hook checks that
  `registerHook` actually exists before running, and soft-disables with a
  clear warning if it doesn't, rather than assuming a version string can be
  trusted (a fork can self-declare any version it likes).

### D12. Cut a version?

The resource is still `0.1.0` in `fxmanifest.lua`. A minor bump to `0.2.0`
has been recommended since the first draft of this document, on the
grounds that everything added is additive and defaults off, so upgrading is
a no-op for anyone who doesn't opt in — and a changelog entry for `0.2.0` is
already drafted and waiting in `CHANGELOG.md`. Worth doing once you settle
D1.

---

## 6. What this process got wrong

You're inheriting work from several rounds of AI-driven development on this
resource. It caught its own mistakes every time listed below, and none of
them reached a live server — but you should know the specific ways this
process has been wrong, not just that it was eventually right.

- **Documentation described security controls that did not exist, twice.**
  Once, a config comment claimed a K9-inventory access mode
  (`accessScope = 'ownerOnly'`) restricted a gear stash to its own K9 —
  it never did, because the underlying `ox_inventory` check that mode
  relied on doesn't compare against the caller's identity at all. It's now
  hard-removed: setting that value crashes the resource on startup rather
  than silently granting broader access than documented. Separately, a file
  header claimed for some time that revoking a certification automatically
  tore down that handler's active partnership — the function to do that
  existed, but nothing ever called it, so the teardown silently never
  happened until someone checked the claim against the code and wired the
  missing calls in.
- **A commit's own message described a fix that wasn't in that commit's
  diff.** A commit claimed to fix inverted stamina math in the vitality
  HUD; the code was in fact already correct, because a different,
  concurrent piece of work had fixed the same thing moments earlier. No bug
  reached you, but it's a reminder that a commit message asserting a fix is
  not proof the fix is actually in that commit.
- **A config comment described an effect landing on the wrong player.** The
  comment above the contraband screen effect said it applied to the
  *searched* person's screen; the code has always applied it to the
  *searching* K9's own handler, as sensory feedback for the search, not a
  penalty on a suspect. The comment was wrong, not the code — but a future
  editor trusting only the comment could have "fixed" working code into
  applying a disorienting effect to the wrong player.
- **A shipped effect referenced an asset that doesn't exist.** The
  contraband screen effect's timecycle modifier name,
  `'drug_wobbly_shroom'`, isn't a real modifier — checked against a full
  extraction of the game's own timecycle data, which has `'drug_wobbly'`
  and nothing resembling the shipped name. The feature would have been
  enabled, run without error, and simply shown nothing, forever, with no
  clue in any log about why. Fixed to the real name.
- **A security bug already fixed once reappeared in a new file.** An
  unguarded "delete this networked object" handler in the deployable-kennel
  feature let a forged client event delete *any* streamed entity on the
  server, not just a kennel, and only worked at all because the handler
  never checked its own feature flag first. That exact combination — no
  flag check, no check that the target is actually the right kind of
  object — was found and fixed in the kennel code, and then had to be found
  and closed again in the newer prop-attachment/bone-sweep file pair before
  those files were allowed into `fxmanifest.lua`. The underlying lesson
  (a new file copying an old pattern can copy its bug too) is now a standing
  item for whoever does security review on the next new feature.

None of these needed action from you, and none are still open. They're
listed because a status document that only reports successes isn't worth
trusting, and because the next feature built on this codebase is more
likely to repeat one of these five failure modes than to invent a new one.
