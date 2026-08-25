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

## 0. Issue-closer triage pass — 2026-08-25

An issue-closer sweep re-checked every item below against the current
source tree (not against this document's own prose, and not against any
commit message at face value) and sorted each into one of three buckets:
**GENUINELY STILL OPEN** (needs a human call, decision stated precisely),
**OVERTAKEN BY EVENTS** (the code changed and the question no longer
applies as originally phrased), or **ANSWERABLE NOW** (enough evidence
exists to close it, flagged for a human to ratify rather than closed
unilaterally — this document exists specifically because these are yours
to sign off on, not ours to close by fiat).

**Counts: 12 original items (D1–D12) reviewed — 8 GENUINELY STILL OPEN
(D1, D2, D3, D6, D7, D8, D9, D12), 2 ANSWERABLE NOW / ratify-to-close (D4,
D5), 2 already self-described as answered and reconfirmed accurate (D10,
D11). One item (D9) had a stale factual premise (the prop model name)
corrected in place. One genuinely new item (D13) was found during this
sweep and is not a re-statement of anything above — see its own heading,
placed immediately after D3 rather than buried at the end, precisely so
it doesn't get lost.**

The single most-blocking open decision, unchanged by this sweep, is
**D3**: two of the three Phase-1 "ships `true`" combat-adjacent items on
the roadmap (Category B combat: `BiteAndHold`, `NonLethalTakedown`,
`PropDragging`) and the newer `FearStressSystem`/`D13` interaction both
sit downstream of whether the `source ~= 65535` guard actually fails
closed. Nothing else here blocks as much at once, and nothing found this
pass moved it any closer to resolved — see D3's own triage note for why,
including one genuinely new piece of reasoning that raises confidence
without proving anything.

Per-item notes are inline below, immediately under each original
item's own text — original wording is untouched; only a triage note is
appended under each.

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

> **TRIAGE: GENUINELY STILL OPEN.** Re-verified against current
> `config.lua`: `Config.Features` still has exactly 40 flags, 5 `true`
> (`LeashMechanics`, `RadialMenu`, `VehicleEntryExit`, `BasicBarkSounds`,
> `AgilityBasicJump`), 35 `false`. This is a product/appetite call about
> your own server, not something code changes could pre-answer — nothing
> about the tranche recommendation has been overtaken. Unchanged.

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

> **TRIAGE: GENUINELY STILL OPEN.** Verified against
> `config.lua`'s `Config.Combat.NonComplianceDetection.action` (still
> constrained to `'log' | 'notify_staff'`, with an explicit comment ruling
> out `'auto_kick'`/`'auto_ban'`) and against `server/combat.lua`'s guardrail
> comments: the "no server-authoritative consequence ever hinges on a
> Category B signal" property still holds. This is a platform-property
> policy call, not something more code can pre-answer — unchanged by
> anything found this sweep. Also see **D13** below, a related but distinct
> new finding: even the *detection* side of Category B (the
> `FearStressSystem`/hesitation gate this same combat surface now consults)
> carries its own, separate PvP-fairness question that didn't exist when D2
> was first written.

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

> **TRIAGE: GENUINELY STILL OPEN — do not close this. This is the
> single most-blocking item in this whole document.**
>
> Three independent passes have now tried to settle this from source and
> all three correctly stopped short of a conclusion, which is the right
> call each time, not a failure to try hard enough:
>
> 1. **`phase2_notes/client_event_trust_boundary.md`** (coder-security,
>    design-only pass) — established the guard is the *official,
>    first-party documented pattern* for exactly this scenario
>    (`citizenfx/fivem-docs`'s "Secure your events" page, read directly),
>    graded MEDIUM-HIGH confidence, and named the exact empirical test
>    needed, explicitly flagging that the raw C++ path populating `source`
>    on a networked receive could not be traced from the one file fetched
>    (`ResourceEventComponent.cpp` showed `eventSource` as a parameter, not
>    the population site).
> 2. **The `95f058c` "Sharpen D3" pass** — read `client/combat.lua` fresh
>    and named the specific fail-**open** mechanism this document
>    describes (a stale, never-cleared `source` global surviving from any
>    prior genuine server event). This is what turned "confirm it fails
>    closed" into "confirm it fails closed, and only via a *sequenced*
>    test" — a real, load-bearing sharpening of the question, not just a
>    restatement.
> 3. **`PROJECT_STATUS.md` §4–5** (project-lead pass) — independently
>    fetched and read FXServer's `citizen-resources-core/
>    ResourceEventComponent.cpp` looking for the same population site, and
>    found `eventSource` is threaded as a plain C++ function parameter at
>    that layer, not stored in a persistent variable — mild, circumstantial
>    evidence *against* the "stale global that never clears" failure mode,
>    since a purely parameter-threaded value has nothing to go stale in *at
>    that specific layer*. Explicitly conceded this is not the layer that
>    actually sets the Lua-visible `source` global (that's the
>    scripting-runtime glue wrapping `AddEventHandler` invocation, in
>    `citizen-scripting-lua` or the resource bootstrap — not located or
>    read by any pass so far) and explicitly declined to upgrade the
>    confidence grading on the strength of it.
>
> **A fourth argument, worth recording formally because it is genuinely
> useful and has not been written down anywhere in this codebase's own
> notes before now, found while cross-checking this sweep:** the
> `source ~= 65535` pattern is not something this resource invented or
> uses in isolation — it is FiveM's own first-party documented idiom, and
> by the nature of a `RegisterNetEvent`/`TriggerEvent` self-invocation
> being available to *any* resource on *any* server via the public Lua API
> (no native-calling capability required — see
> `client_event_trust_boundary.md` §3's "ubiquitous, low-effort cheat
> menu" framing), this exact guard is near-certainly load-bearing in a very
> large number of FiveM resources across the whole ecosystem, not just
> this one. If it failed open the way this document describes — a stale,
> never-cleared `source` surviving from any prior genuine server event,
> which every connected client acquires within seconds — that would be an
> ecosystem-wide, trivially-reproducible authentication bypass in one of
> the platform's own recommended security idioms, not a subtle edge case.
> The fact that this is not widely known or discussed as a live
> vulnerability raises genuine confidence that the guard does fail closed
> in practice. **This is corroborating reasoning, not proof, and must not
> be treated as settling the question**: it is an argument from absence
> (nobody has loudly reported this failure mode) in a threat model that
> specifically requires a *sequenced* test to even notice — a tester who
> only fires a local `TriggerEvent` on a fresh client (the "naive" test
> `OPERATOR_RUNBOOK.md` §3 explicitly warns against) would see it "pass"
> either way and have no reason to ever report a problem. Absence of
> ecosystem-wide public reporting is not the same as absence of the bug;
> it is exactly the shape of evidence you'd also see if the bug were real
> but nobody had ever tested it in the right order. Confidence raised;
> question not resolved.
>
> **The sequenced in-engine experiment is still stated clearly enough to
> run tomorrow** — verified current in `OPERATOR_RUNBOOK.md` §3 ("The
> sequenced origin-guard check"), which gives the exact four-step
> procedure (connect a test client → let it receive one genuine
> server-originated event, e.g. the default-`true` bark → from that SAME
> client, without reconnecting, fire a local `TriggerEvent` against a
> guarded handler → compare whether `source` still reads `65535` on the
> forged call). As of this sweep, `git log`/`WATCHDOG_LOG.md` show no
> record of anyone having actually run it. **Do not let this item be
> closed by another source-reading pass — it can only be closed by running
> that test, or by a human deciding to accept the risk as documented in
> D3's own "Your call" above.**

### D13. [New this sweep — not in the original draft] Is the bounded hesitation-lockout griefing vector acceptable for live PvP?

This item did not exist in any prior version of this document. It is
placed here, immediately after D3 rather than at the end, because it is
closely related (it also gates part of the combat feature surface) and
because burying a new open question inside a wall of already-closed items
is exactly the failure mode this sweep was asked to avoid.

**What it is**: `Config.Features.FearStressSystem` (still `false`) drives a
K9's Fear/Stress stat up from nearby gunfire reports
(`server/wellbeing.lua`'s `relayWeaponFire` handler). Once stress crosses
`Config.Wellbeing.FearStress.hesitationThreshold` (currently `85`), the K9
enters a hesitation state, and `server/combat.lua`'s `ValidateCombatRequest`
hard-rejects that K9's `BiteAndHold`/`NonLethalTakedown` requests for as
long as hesitation is active. The gunfire-report event is, by design,
payload-less and unauthenticated as to *which* gunfire it refers to
(`server/tracking.lua`'s own "FORGED TRAIL DECISION" already accepted this
for its own, lower-stakes consumer) — so any connected player, standing
within `Config.Wellbeing.FearStress.gunfireRadius` (20m) of a K9 that
isn't even theirs, can repeatedly fire the relay event to keep that K9
hesitating, indistinguishably from a real, continuous nearby shooter.

**What is already fixed, not what's still open**: a real, in-code fix
(`server/wellbeing.lua`'s `HESITATION_MAX_CONTINUOUS_MS`, currently
`Config.Wellbeing.FearStress.hesitationDurationMs * 8` = 64 seconds) caps
any single continuous hesitation episode, after which stress is
force-reset to 0 and the attacker must re-climb the threshold from
scratch before hesitation can resume. This closed the *indefinite* version
of the exploit — confirmed by reading `server/wellbeing.lua` directly, not
from its own comment alone. What is **not** closed, and cannot be closed
by more code per that same file's own header (the signal is structurally
unauthenticatable — there is nothing to corroborate it against), is the
**bounded, repeatable** version: a single attacker standing near a K9 they
have no other relationship to can force that K9 into repeated ~64-second
combat-command lockouts, at a cost of roughly one forged network call per
minute to sustain, for as long as they choose to stay nearby.

**The decision this needs**: is a bounded, repeatable, ~64-second-at-a-time
denial of one specific K9's `BiteAndHold`/`NonLethalTakedown` commands —
triggerable by *any* connected player, with no relationship to the K9 or
its handler required, at effectively zero cost or skill — an acceptable
griefing surface for your server's live PvP, given `FearStressSystem` also
still ships `false` by default? This is the same shape of tradeoff D2
already asks you to accept for Category B combat generally, but it is a
**distinct** mechanism (a detection/gating signal being forged, not an
effect being ignored) and was never disclosed as a named, numbered decision
before now — it lived only in `server/wellbeing.lua`'s and `config.lua`'s
own inline comments. Nothing here recommends an answer: the numeric bound
(64s / ~20m radius / one call per minute) is tunable in
`Config.Wellbeing.FearStress` and `server/wellbeing.lua`'s
`HESITATION_MAX_CONTINUOUS_MS` constant, but retuning the numbers changes
the shape of the exposure, not whether it's acceptable at all. **Your
call**: ship `FearStressSystem` together with combat as-is and accept this
as a disclosed, bounded risk; ship `FearStressSystem` without ever gating
combat on it (i.e. keep it cosmetic-only, never call `IsHesitating()` from
`server/combat.lua`); or leave `FearStressSystem` off entirely until this
is retuned or redesigned to your satisfaction.

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

> **TRIAGE: ANSWERABLE NOW — ratify as closed.** Re-verified directly
> against current `config.lua`: `Config.XPTiers` carries exactly the
> `scentRangeMultiplier` field described (1.00 / 1.05 / 1.10 / 1.20 across
> Recruit/Trained/Veteran/Elite), applied as a multiplier, not the old flat
> floor. The described defect and fix both check out against the live
> code, not just the changelog's account of them. Nothing left to decide
> except optional numeric tuning — recommend a human simply confirm this
> reads as intended and move on.

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

> **TRIAGE: ANSWERABLE NOW — ratify as closed, and note it was hardened
> further after this text was written.** The fix described above left one
> residual gap of its own, since closed: `CHANGELOG.md`'s "Sixth [XP farm]"
> entry and `server/search.lua`'s own `ContrabandXpMintCooldown` (confirmed
> present and wired at the `AwardXP('searchContrabandFound')` call site,
> ~line 1143) add a per-searcher, 60-second mint-floor cooldown closing the
> remaining "toggle the trunk's contents to make the weight differ every
> cycle" angle this item's text doesn't mention. Confirmed by reading
> `server/search.lua` directly, not assumed from the changelog. This item's
> own "No action needed" conclusion still holds and is, if anything, more
> true now than when written — the description here is just slightly
> incomplete, not wrong.

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

> **TRIAGE: GENUINELY STILL OPEN.** Verified against current
> `server/inventory.lua`: the runtime capability check described (a
> `pcall`-guarded probe for `exports.ox_inventory.registerHook` before ever
> calling it, soft-disabling with a clear warning if absent — see that
> file's own "RUNTIME CAPABILITY CHECK" section) is real and present. That
> only removes the *crash* risk, not the *field-name-drift* risk this item
> is actually about — a live-payload logging check against your own
> `ox_inventory` build has still not been run by anyone, and no amount of
> further source-reading can substitute for it. Unchanged, still yours to
> do.

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

> **TRIAGE: GENUINELY STILL OPEN — this is one of the two items this
> sweep was specifically asked to double-check for a live duplicate.**
> Verified against `html/sounds/CREDITS.md` (last touched by commit
> `974f276`, "Verify the bark-audio licences; two of four leads were
> mislicensed") and against `html/sounds/`'s actual directory listing:
> still only `CREDITS.md`, zero audio files of any kind, matching this
> item's own "nothing was downloaded" claim exactly. The three-option
> framing (OGA-BY / CC BY-SA / commission-or-silence) in this item's text
> matches `CREDITS.md`'s own "LICENCE VERIFICATION PASS — 2026-08-25"
> section verbatim — no drift found. **This sweep had no live-agent
> visibility (`ListAgents` was unavailable in this session) to confirm
> whether a peer is actively re-researching this same question right now**;
> if one is, their findings should supersede this note rather than being
> duplicated — but as of the tree read for this sweep, the research reads
> complete and this decision is a pure licensing-policy call, not a
> research gap. This is precisely the "attribution-required audio licences
> — acceptable or not" question: still open, still yours.

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

> **TRIAGE: GENUINELY STILL OPEN.** Verified against
> `client/propattachment.lua`: the vest attach still hardcodes `boneIndex`
> to `0` (root bone) with a comment naming this exact tradeoff. `Config`
> still gates `client/bonetool.lua`/`server/bonetool.lua` behind their own
> feature flag (`BoneSweepDevTool`) *and* an ACE permission, matching this
> item's description. Nobody has run the sweep — this is a live-server
> action item, not something a source-reading pass can pre-answer.
> Unchanged.

### D9. Confirm the kennel prop model?

`client/kennel.lua` ships `prop_doghouse_01` on a single unverified source,
with a documented fallback and a graceful failure path if the model never
loads. Worth eyeballing on a dev server before enabling
`DeployableKennel`. Low stakes — it degrades safely to an obviously-wrong
placeholder object rather than breaking anything.

> **TRIAGE: OVERTAKEN BY EVENTS on the specific model name — the
> underlying decision (eyeball it on a dev server before enabling) is
> GENUINELY STILL OPEN.** This item's premise is stale: `prop_doghouse_01`
> was refuted and replaced by commit `a65dd5d` ("Refute the kennel prop
> model..."), and `config.lua` now ships `propModel = 'prop_dog_cage_01'`
> (verified directly, line 879) with `fallbackPropModel = 'prop_tennis_ball'`
> (line 894) — not the name this item names. The replacement rests on
> materially stronger evidence than the original ("does not appear in a
> 5,171-entry live object database with per-entry rendered screenshots;
> the new name does, with a real render" — per `a65dd5d`'s own commit
> message), but the commit's own author explicitly declined to call this
> exhaustive proof of non-existence for the old name, only checkable
> refuting evidence for it and corroborating (not just asserted) evidence
> for the replacement. The recommendation this item makes — eyeball it on
> a dev server before flipping `DeployableKennel` to `true` — is unaffected
> by the name swap and remains exactly as open as before. Whoever next
> touches this document should update D9's own header text to name
> `prop_dog_cage_01`, not `prop_doghouse_01` — left as-is here per this
> sweep's "preserve original text, append status" rule, but flagged so the
> next editor doesn't propagate the stale name.

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

> **TRIAGE: the "top three are done" claim is ANSWERABLE NOW (ratify as
> accurate) — the "what next, if anything" question is GENUINELY STILL
> OPEN, and correctly so, since it's a direction/priority call, not a
> fact.** Re-verified directly: `server/exports.lua` has exactly 9 real
> `exports(...)` call sites (`GetAPIVersion`, `HasK9Access`,
> `IsConfiguredK9Model`, `IsK9Department`, `GetActivePartnerCitizenId`,
> `IsActivePartnerOf`, `GetXP`, `GetXPTier`, `IsFeatureEnabled`), and
> `README.md`'s own "Commands"/API section confirms all six outbound
> events (`certificationGranted`/`certificationRevoked`/
> `partnershipEstablished`/`partnershipEnded`/`searchCompleted`/
> `xpTierReached`) are wired and firing at real call sites across
> `server/certifications.lua`/`partnership.lua`/`progression.lua`/
> `search.lua`, not just declared. `server/admin.lua`'s three audit
> commands and `server/tenure.lua`'s milestone bonuses are both present
> and registered. Nothing here needs a human decision except "which
> further item from `COMPLEMENTARY_FEATURES.md`'s remaining list, if any,
> do you want next" — which is exactly what this item already says, so no
> change needed beyond confirming it still holds.

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

> **TRIAGE: ANSWERABLE NOW — already correctly self-labelled "ANSWERED" in
> its own heading, and this sweep found no reason to disagree.**
> Independently re-verified `fxmanifest.lua`'s `dependencies {}` block:
> still five bare resource-name strings (`qbx_core`, `ox_lib`, `ox_target`,
> `oxmysql`, `ox_inventory`), no `@`/`>=`/version syntax anywhere. The
> "last verified compatible" table in `README.md` still reads `qbx_core`
> 1.24.0 / `ox_lib` 3.39.0 / `ox_target` 1.18.1 / `oxmysql` 2.14.1 /
> `ox_inventory` 2.47.9, matching this item's own figures exactly. This
> sweep did not re-fetch `citizenfx/fivem`'s C++ source to re-derive the
> core "no version syntax exists" claim from scratch (no drift signal
> pointed at it, and `PROJECT_STATUS.md`'s own prior pass already disclosed
> not re-deriving it for the same reason) — flagging that as inherited,
> not independently re-proven, trust, same honest caveat the prior pass
> gave. Nothing for a human to decide here beyond noting the doc-only
> mitigation already shipped.

### D12. Cut a version?

The resource is still `0.1.0` in `fxmanifest.lua`. A minor bump to `0.2.0`
has been recommended since the first draft of this document, on the
grounds that everything added is additive and defaults off, so upgrading is
a no-op for anyone who doesn't opt in — and a changelog entry for `0.2.0` is
already drafted and waiting in `CHANGELOG.md`. Worth doing once you settle
D1.

> **TRIAGE: GENUINELY STILL OPEN, and the situation has moved further in
> the direction this item already predicted, not against it.** Verified:
> `fxmanifest.lua` still reads `version '0.1.0'` exactly. `CHANGELOG.md`
> still carries a fully-drafted `## [0.2.0] - 2026-08-24` section — but a
> substantial amount of further work (the six XP-farm closures, the six
> no-op-native fixes, the seventeen orphaned-object fixes, the
> certification-grant race fix, the full 12-file/434-case test suite, most
> of the locale migration, D3's sharpening, and D9's prop-model
> correction) has landed **since** that `0.2.0` section was written and
> currently sits under `## [Unreleased]` above it, not folded into it. The
> underlying decision ("cut a version, once you settle D1") is unchanged
> and still entirely yours — but whoever does eventually cut a version
> should treat `[Unreleased]` as the real diff against `0.1.0`, not the
> `[0.2.0]` section alone, which is now itself an intermediate snapshot,
> not the current state.

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
