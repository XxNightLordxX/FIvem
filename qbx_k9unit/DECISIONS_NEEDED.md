# qbx_k9unit — Status & Decisions Needed

Written 2026-08-24. Covers the whole resource as it stands, and lists the
calls that are genuinely yours to make rather than ours.

Nothing in this document is urgent in the "production is broken" sense —
**every feature built this session ships `false` by default**, and the five
Phase 1 features that are `true` have been re-verified conformant. The
decisions below gate whether any of the rest gets switched on.

---

## 1. Where the resource actually stands

29 Lua files, 91 commits. Lint and syntax are at a genuine zero across the
resource, and CI runs both on every push.

**Live today** (`true` in `config.lua`): leash mechanics, radial menu,
vehicle entry/exit, basic bark, basic jump/crouch.

**Built and reviewed, shipping off**: scent/blood/gunpowder tracking,
contraband search + audit log, thermal/night vision, door scratch and
nudge, bite-and-hold, non-lethal takedown, prop dragging, advanced agility
vault, K9 inventory stash, medkit, XP progression, the five-stat wellbeing
system, health/stamina HUD, deployable kennel, advanced bark radial,
handler partnership registry.

**In flight as of writing**: HandlerDownDefense, Recall, contraband screen
FX, the NUI audio bridge, and a client-event origin check.

**Researched and deliberately not built**: `CameraFeedPiP` — no native
exists to render a secondary camera into a NUI texture. There is an open
upstream citizenfx issue requesting exactly that native. This one is
closed as impossible, not deferred.

---

## 2. Decisions that block enabling anything

### D1. Which features do you actually want on?

This is the big one and everything else is downstream of it. Thirty-one
feature flags exist; five are on. We built to spec, but we don't know your
server's appetite — a K9 unit that can drag downed players and bite
suspects is a very different fit from one that tracks scent and searches
trunks.

Suggest picking a first tranche to enable and playtest, rather than
flipping everything. The tracking/search set (`ScentTracking`,
`BloodTracking`, `GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`)
is the lowest-risk group — read-only, no player-vs-player state, and the
most thoroughly reviewed. Combat is the highest-risk group, for reasons in
D2.

**Caveat on `ScentTracking` specifically**: it needs a one-time live check
first, see D6.

### D2. Do Category B combat effects ship, knowing a modified client can ignore them?

Bite-and-hold, non-lethal takedown and prop dragging split into two kinds
of effect. **Category A** (the attach in prop dragging) is server-applied
and holds against a hostile client. **Category B** (movement restriction,
forced ragdoll, damage bracket) is inherently local — it only means
anything if the *target's own client* executes it, and a modified client
can simply decline.

We shipped Category B under five guardrails, the important one being that
no server-authoritative consequence is ever gated on a Category B signal
succeeding. Non-compliance is detected and logged, never punished
automatically.

**Your call**: accept that a cheater can shrug off a bite hold, or keep
these three features off. There is no third option — this is a property of
how FiveM distributes entity authority, not something more code fixes.
Most servers accept it; we're flagging it rather than letting you discover
it from a player complaint.

### D3. Ship the client-event origin check on medium-high confidence, or verify in-engine first?

A real exploit was found and fixed this session: client-side net event
handlers could not distinguish a genuine server message from a local
`TriggerEvent` the player fired themselves. Any player could loop one call
for indefinite invincibility — **with the features switched off**, because
only the server checked the flags and that path never reached the server.

Per-mechanic gating closed the flags-off case. The deeper fix is
`if source ~= 65535 then return end` at the top of each handler, which is
CitizenFX's own documented pattern from their security guide.

**But we graded it medium-high, not certain.** We confirmed from primary
source that the native behind `TriggerEvent` takes no origin parameter, and
found the official pattern in CFX's docs — but we could not reach the
forums or trace the C++ path that populates `source` on network receive.
The recommendation is an empirical in-engine check before trusting it.

**Your call**: ship it as-is (it's strictly better than nothing and costs
one line per handler), or have someone confirm on a dev server first. If
you enable any combat feature, this matters more.

---

## 3. Decisions about the XP economy

Two real defects were found in audit. Both need a product call, not just a
code fix.

### D4. What should the XP tier scent bonus actually be?

`Config.XPTiers` grants `scentRange` per tier — 5.0 / 6.5 / 8.0 / 10.0
from Recruit to Elite. It is applied as a floor against the tracking
config's own `maxRange`, which is **40.0 for every track type**. Since even
the Elite value never exceeds 40, this bonus has never done anything. The
"scent range grows with XP" reward is numerically dead as shipped.

**Your call**: pick real numbers above 40 (something like 42/48/55/65), or
change the mechanic to a multiplier over each type's own range. The second
is cleaner but changes the balance shape.

### D5. How should contraband-search XP be limited?

`searchContrabandFound` awards 25 XP whenever a search finds contraband.
The only limiter is a 10-second per-target cooldown, and the result is
computed deterministically from real inventory contents. A handler can
plant contraband in their own trunk and re-search it every 10 seconds:
roughly 9,000 XP/hour, reaching the top tier in under half an hour with no
travel and no risk.

Two sibling awards got anti-farm floors this session — a minimum travel
distance for track sources, a minimum hold duration for bite-and-hold.
This one never did.

**Your call, roughly in order of effort**: require the contraband to change
or be seized between awards; add a long XP-eligible cooldown per
(searcher, target) separate from the anti-harassment cooldown; or cap
daily XP from searches.

---

## 4. Decisions needing something only you can supply

### D6. Run the one-time `ox_inventory` check for scent tracking?

Scent tracking depends on `exports.ox_inventory:registerHook('swapItems', ...)`.
The hook name and payload shape were confirmed by reading ox_inventory's
source directly — the docs site is unreachable from our environment — but
never verified against a live install. The recommended check is logging the
payload once on a dev server to confirm field names before trusting it.

`Config.Features.ScentTracking` stays `false` until someone does this.
It's a five-minute job for anyone with a dev server.

### D7. Supply bark audio, or accept silence?

Every bark in this resource is a placeholder soundset name that resolves to
a harmless no-op. There is no real audio anywhere, and the advanced bark
radial widened that gap rather than closing it — it now has three silent
variants instead of one.

The cheaper path we identified is extending the NUI bridge (in progress),
which drops the requirement from "author RAGE `.awc`/`dat151`/`dat54` audio
banks" to "supply three licensed `.ogg` files."

**Your call**: source three `.ogg` files, commission them, or accept that
barks stay silent and drop `AdvancedBarkRadial` from your enable list.
We deliberately did not fabricate or download any audio.

### D8. Run the bone-index sweep for prop attachments and fetch?

Three separate research passes failed to find a documented bone name for a
quadruped skeleton, and reading two open-source dog scripts found nobody
attaching props to an animal ped at all. The reframe that unblocks it:
`AttachEntityToEntity` needs a bone **index**, not a name, and
`GetWorldPositionOfEntityBone` is entity-type-agnostic — so the real method
is a short in-engine sweep to identify the right index visually.

This is a bounded ~20-line dev-server test, and it unblocks both
`PropAttachments` (a visible vest) and `FetchMechanic`'s mouth carry.

**Your call**: run it, or leave both features unbuilt.

### D9. Confirm the kennel prop model?

`client/kennel.lua` ships `prop_doghouse_01` on a single unverified source,
with a documented fallback and a graceful failure path if the model never
loads. Worth eyeballing on a dev server before enabling
`DeployableKennel`. Low stakes — it degrades safely.

---

## 5. Decisions about direction

### D10. Which complementary work, if any?

From `COMPLEMENTARY_FEATURES.md`, ranked by value-per-effort:

1. **Ship an export/event surface.** This resource currently declares
   **zero exports**. That makes it a prerequisite for almost any
   integration with dispatch, MDT or evidence systems — not a nice-to-have.
   Cheap.
2. **In-game admin/audit surface** for the certification, partnership and
   search-log tables. Today those are documented as raw SQL an admin runs
   by hand. The data is already written; this is just a command wrapper.
3. **Partnership-tenure bonuses.** The registry landed with no gameplay
   consequence attached to it yet. The most direct payoff on infrastructure
   already built.

Verified maintained: `ps-dispatch`, `ps-mdt` (real evidence exports),
`qbx_ambulancejob`/`qbx_medical`. Verified **dead**: `qbx_prison` is
explicitly "Not Maintained" — don't build against it. We could not confirm
canonical repos for `cd_dispatch`/`qs-dispatch` despite `config.lua` naming
them by convention.

### D11. Pin dependency versions? — ANSWERED, and the answer is "you can't"

**Do not attempt this.** Verified against the FiveM engine's own C++ source
(`ResourceDependencyLoader.cpp`, `ResourceManagerConstraintsComponent.cpp`,
`ServerResources.cpp`, read directly from a clone of `citizenfx/fivem`):
the `dependencies` block has **no version-constraint syntax at all**. A
string is only treated as a constraint if it begins with `/`, and the only
constraints the engine defines are `/server:BUILD`, `/onesync`,
`/gameBuild:BUILD` and `/native:0xHASH`. Everything else is a literal
resource-name lookup.

So writing `'ox_inventory@2.47.9'` or `'ox_inventory >=2.47.9'` would not
pin anything — it would fail to resolve as a resource name and **hard-break
this resource's startup**. Corroborated against four live upstream
manifests (`ox_lib`, `ox_target`, `ox_inventory`, `qbx_core`), none of which
encodes a version in a dependency entry.

**What to do instead**, and this is the actual decision:

- A documentation-only "last verified compatible" note in the manifest.
  Verified this session by reading each dependency's source: `qbx_core`
  1.24.0, `ox_lib` 3.39.0, `ox_target` 1.18.1, `oxmysql` 2.14.1,
  `ox_inventory` 2.47.9. Honest caveat: these are "newest version the
  assumptions were checked against," not proven minimums — nobody
  git-blamed how far back each API goes.
- A **runtime capability check** for `ox_inventory` specifically, which is
  the only dependency with version-sensitive behaviour this resource relies
  on. Checking that `registerHook` actually exists before letting
  `ScentTracking` run is more trustworthy than a version string, because a
  fork can self-declare any version it likes.

**Your call on that last point**: hard `assert` (resource refuses to start)
or soft-disable the feature with a warning. The recommendation is
soft-disable — a missing hook makes the feature silently inert, not
silently exploitable, and this resource reserves hard asserts for
actively-dangerous states like the two access-control invariants.

### D12. Cut a version?

The resource is still `0.1.0`. A minor bump to `0.2.0` was recommended
earlier on the grounds that everything added is additive and defaults off,
so upgrading is a no-op for anyone who doesn't opt in. Worth doing once you
settle D1.

---

## 6. Things you should know but don't need to decide

- **Two headers described controls that did not exist.** One claimed an
  inventory access mode that provided no access control whatsoever; one
  claimed teardown call sites that were never written. Both are fixed, and
  both were found by someone verifying a claim rather than trusting it.
  Worth knowing the docs have been wrong in this specific way twice.
- **A "real bug fix" was itself possibly broken.** The fix for a
  non-lethal takedown that could kill omitted a native this resource's own
  research notes list as required. Fixed, and disclosed as best-effort
  because no success-check native is confirmed available.
- **The partnership feature briefly had a join path and no leave path** —
  the exact unbounded trap the design forbids. Being fixed now.
- **`REFACTOR_ROADMAP.md` item 2 was marked done and wasn't** — four files
  written afterwards re-created the pattern 11 times. Corrected, and the
  migration is in progress.

None of these need action from you. They're listed because a status
document that only reports successes isn't worth reading.
