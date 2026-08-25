# qbx_k9unit — Whole-Project Status Assessment

> **Documentation sync correction, 2026-08-25.** This document is dated
> 2026-08-24 and roughly a dozen commits have landed since, resolving the
> single biggest risk it identified. Read the numbers and narrative below as
> a snapshot of that date, not current fact, with these specific corrections:
>
> - **§2's "uncommitted work" risk is resolved.** Every file this section
>   listed as uncommitted (`client/recall.lua`/`server/recall.lua`,
>   `client/audio.lua`, `client/exports.lua`/`server/exports.lua`,
>   `server/admin.lua`, `server/tenure.lua`, the SQL migrations) is present
>   in `fxmanifest.lua`'s script lists today and documented as shipped in
>   `CHANGELOG.md` — direct evidence the working tree this section worried
>   about losing was not lost. This pass could not independently run `git
>   status`/`git log` to confirm the commit history itself (no shell access
>   from this documentation-only pass), so treat "resolved" as
>   file-state-verified, not git-history-verified — worth a `git log`
>   glance before fully retiring this as a concern.
> - **The flag count in §0 (39) undercounts by one.** A direct read of
>   `config.lua`'s `Config.Features` table (not a regex — a naive
>   alphanumeric regex misses names containing a digit, like `K9Inventory`/
>   `K9Medkit`, which is exactly how this document's own predecessor drafts
>   mis-counted before) gives **40** flags: 5 `true`, 35 `false`.
> - **Genuinely new since this pass**: `Config.K9Inventory.allowedItems` is
>   now really enforced via an `ox_inventory` `registerHook` veto (§4/§7
>   below described it as having no effect — that was accurate when
>   written); a real (partial) flashbang-immunity accessor exists for
>   `DistractionSystem`; `FatigueSystem`'s rest-source regen is wired; six
>   radial menu entries (Partner Up, Recall K9, Handler-Down Response,
>   Fetch, Toggle K9 Vest, Deploy Kennel) closed the last "implemented but
>   only reachable by command" gaps this document's §1 table implicitly
>   assumed still existed; a TOCTOU window in `HandlerPartnership`'s accept
>   flow was closed; two K9 Medkit defects (a dead-K9 healing gate, a mutex
>   permanently locking on a hypothetical uncaught error) and one
>   `FetchMechanic` carrier-disconnect state bug were fixed; the NUI audio
>   bridge (`client/audio.lua`) now has a real caller from `client/main.lua`;
>   the client export surface bumped to `1.1.0` (server stays `1.0.0`); and
>   the bark-audio licensing question this document's §5 left open has
>   sharpened from "unverified leads" to "real candidates exist, none are
>   public domain" (CC BY-SA or OGA-BY) — see `CHANGELOG.md`'s `[Unreleased]`
>   section for the full, verified detail on all of the above.
> - Everything else below was **not** re-verified line-by-line in this pass
>   (this was a documentation-reconciliation pass scoped to the six landed
>   items above, not a full re-audit) — in particular, §7 item 6's call to
>   re-run the flag-off-safety sweep against `defense.lua`/`recall.lua`/
>   `screenfx.lua`/`audio.lua`/`admin.lua`/`exports.lua`/`tenure.lua`, and
>   §5's D5-equivalent XP-farm-composition risk, were **not** independently
>   re-checked here and should still be treated as open exactly as this
>   document originally left them.

Author: project-lead pass (read-only on code), 2026-08-24.
Scope: cross-phase assessment of the entire resource as it stands on
`claude/code-improver-subagent-qlt3bn`, cross-checked against git history,
current file contents, and one live external re-verification (ox_inventory's
current upstream source). This document does not replace
`DECISIONS_NEEDED.md` (which is current, accurate, and the right place for
the owner's actual decisions) — it corroborates it, adds what a pass with
fresh eyes and external reach could newly check, and flags two doc-drift
findings the project's own recent commits introduced.

---

## 0. Ground truth numbers (verified this pass, not taken from a doc)

- **97 commits** on this branch (`git log --oneline | wc -l`), 2 ahead of
  `DECISIONS_NEEDED.md`'s "91 commits" (it was written before the last two
  landed).
- **40 `.lua` files** on disk right now (28 committed at `HEAD`, 12
  uncommitted — 6 modified, 6 new/untracked — see §2). `luac5.4 -p` parses
  all 40 clean. `luacheck` (repo-root `.luacheckrc`) reports **0
  errors / 13 warnings**, and every one of those 13 warnings sits inside the
  uncommitted work described in §2 — the committed tree at `HEAD` is
  genuinely lint-clean.
- **39 `Config.Features` flags** in the current `config.lua` (not "30+" —
  actually counted: 5 Phase‑1 flags `true`, 34 flags `false`). This includes
  four flags (`Recall`, `HandlerPartnership`, `PartnershipTenureBonus`,
  `AdminAuditCommands`) whose config entries already exist but whose
  implementing files are not yet loaded by `fxmanifest.lua` at all — see §2.
  So the practically-relevant count for "what could a server owner turn on
  today" is smaller than 39 until that wiring lands.
- Working tree is **not clean**: 6 modified files
  (`server/certifications.lua`, `server/tracking.lua`, `server/combat.lua`,
  `client/inventory.lua`, `sql/install.sql`, `.github/workflows/lua-check.yml`)
  and 10 new untracked files/dirs (`client/audio.lua`, `client/exports.lua`,
  `client/recall.lua`, `client/screenfx.lua`, `html/sounds/`,
  `server/admin.lua`, `server/exports.lua`, `server/recall.lua`,
  `server/tenure.lua`, `sql/migrations/`). None of this is committed
  anywhere — see §2 for why that matters.

---

## 1. Phase-by-phase status (verified against code, not against a status line)

| Phase | Spec'd scope | Status |
|---|---|---|
| **1 — vertical slice** | Certification, leash, radial, vehicle, basic bark, basic jump | **Done, live, re-verified.** 5 flags ship `true`. The 5 standing regression checks `WATCHDOG_LOG.md` has run every pass since Pass #1 all still hold at `HEAD` (spot-checked again this pass: `AgilityBasicJump` gate, role-aware `LeashPairs`, `RevokeCertificationOffline`→`RefreshCertificationCache`, vehicle `onResourceStop` cleanup, radial's registration-order fix). |
| **2 — tracking/search/vision/door** | Scent/blood/gunpowder tracking, search zones, contraband alerts, thermal/night vision, door interaction | **Implementation-complete, ships false.** All code paths exist and are reviewed. `ScentTracking` specifically is gated on a live-install payload check (D6) that this pass **partially closed** — see §5. |
| **3 — combat/action** | Bite-and-hold, non-lethal takedown, handler-down defense, prop dragging, advanced agility | **Code-complete for all five**, including `HandlerDownDefense`, which landed in the very last committed commit (`4ebd078`) after `DECISIONS_NEEDED.md` was written and described it as still in-flight. All five are reachable via `client/radial.lua`. All ship `false`. `Recall` (the sixth Phase‑3 mechanic, the handler's "call off the dog" escape hatch) is **implemented but uncommitted** — see §2. |
| **4 — inventory/progression/vitality** | Stash, XP, HUD, wellbeing (5 stats), medkit, contraband screen FX | **Code-complete.** `ContrabandScreenFX` (the one item `DECISIONS_NEEDED.md` still listed as "not yet coded" is in fact committed as `client/screenfx.lua` at `HEAD` — confirmed by reading the file). All ship `false`. |
| **5 — audio/props/camera R&D** | Advanced bark radial, proximity audio, prop attachments, fetch, kennel, camera PiP | **Mixed.** `AdvancedBarkRadial` and `DeployableKennel` are code-complete and ship `false`. `ProximityAudioFX`/`PropAttachments`/`FetchMechanic` are researched (concrete next steps identified, see `phase2_notes/phase5_remaining_features_research.md`) but not coded. `CameraFeedPiP` is correctly closed as infeasible (no native exists; confirmed against a real open citizenfx/fivem issue). The NUI **audio bridge** (`client/audio.lua`) that would finally give barks real sound is **implemented but uncommitted and not yet wired into `client/main.lua`** — its own header explicitly flags "ONE-LINE CHANGE main.lua STILL NEEDS," and that one line has not landed. |

**Correction to my own reading of `DECISIONS_NEEDED.md`:** that document (dated
today) already says "in flight: HandlerDownDefense, Recall, contraband
screen FX, the NUI audio bridge, and a client-event origin check." That was
accurate at the moment it was written. Two of those five ("HandlerDownDefense"
and "a client-event origin check") landed and got committed one commit later
(`4ebd078`). The other three (Recall, screenfx wiring's last mile, audio
bridge) are still sitting uncommitted in the working tree as of this pass —
see §2. `ContrabandScreenFX` itself, however, is committed and code-complete;
only the *audio* piece of "in flight" work remains genuinely unfinished.

---

## 2. The uncommitted work — a bigger finding than any single doc claim

Ten new files and six modified files sit uncommitted in the working tree,
representing substantial, apparently-complete feature work that is **not
in git history at all**:

- `client/recall.lua` + `server/recall.lua` — Recall (Phase 3's sixth
  mechanic, the handler's escape hatch for a bite/takedown/drag in
  progress). Config flag `Recall` already exists in the committed
  `config.lua`.
- `client/audio.lua` — the NUI audio bridge for real bark sound.
- `client/exports.lua` + `server/exports.lua` — the export/event API
  surface, i.e. `COMPLEMENTARY_FEATURES.md`'s own #1-ranked recommendation,
  already being built.
- `server/admin.lua` — the in-game ACE-gated admin/audit surface,
  `COMPLEMENTARY_FEATURES.md`'s #2-ranked recommendation. Config flag
  `AdminAuditCommands` already exists.
- `server/tenure.lua` — the partnership-tenure XP bonus,
  `COMPLEMENTARY_FEATURES.md`'s #3-ranked recommendation. Config flag
  `PartnershipTenureBonus` already exists.
- `sql/migrations/0001-0003*.sql` — migration files for existing installs
  (partnerships, progression, the new tenure-bonus column).
- `html/sounds/` — presumably assets for the audio bridge (see §5 on
  whether these are real audio or still placeholders — not independently
  confirmed as licensed audio this pass).
- Modified `server/certifications.lua`, `server/tracking.lua`: add
  `FireOutboundEvent`-style wrappers, apparently to power the new export
  surface.
- Modified `server/combat.lua`: exposes `EndActiveEffectForHolder` as a
  resource-global — this is what `server/recall.lua` calls to actually end
  an active bite/takedown/drag.
- Modified `client/inventory.lua`, `sql/install.sql`,
  `.github/workflows/lua-check.yml`.

**This is, in effect, exactly the top three items `COMPLEMENTARY_FEATURES.md`
recommended, already built, in parallel with the D1-decision document being
written.** That's a healthy sign of momentum, but it creates a real,
practical risk: **none of it is committed, and none of it is wired into
`fxmanifest.lua`** (which the user now owns and which I could not check
whether anyone else is actively editing). `luacheck` confirms this directly
— all 13 warnings in the whole resource are cross-file "undefined global"
warnings inside exactly these files (`RequestRecall`, `EndActiveEffectForHolder`,
`SetTimecycleModifier`/`ClearTimecycleModifier` in `screenfx.lua`,
`PlayK9Sound`/`StopK9Sound` in `audio.lua`, `TriggerEvent` in the two
modified server files) — every one of them is the *expected* shape of
"a resource-global another file will consume, not yet declared in
`.luacheckrc`," not a real bug. But until someone (a) commits this work, (b)
adds the new files to `fxmanifest.lua`'s script lists, and (c) adds the new
globals to `.luacheckrc`, it is functionally invisible: dead code that
doesn't even load. **If this working tree were lost (a bad `git clean`, a
container recycle, a careless `git checkout .`), roughly ten files' worth of
apparently-complete feature work would vanish with no commit to recover
from.** This is the single most concrete, avoidable risk this pass found —
see §7.

I did not commit anything (out of scope for this pass), but flagging this
for the owner's immediate attention is the most actionable thing in this
report.

---

## 3. Drift from spec — the three flagged divergences, all verified as considered improvements

I read the actual code, not just the divergence write-ups, for all three.

**1. `PHASE3_SPEC.md`'s `HandlerDownDefense` premise.** Confirmed: the spec
text (§12.2's comment: `hostileLookbackSeconds`, "reusing Phase 2's
relayDamageEvent log") assumed `relayDamageEvent` carries an attacker
identity. `server/defense.lua`'s header directly quotes `server/tracking.lua`'s
own design constraint (payload deliberately excludes an attacker/source
field, per `phase2_notes/scent_blood_tracking.md`'s explicit warning against
ever adding one) and explains the resolution: a **new, separate,
low-trust hint channel** (`qbx_k9unit:server:reportHandlerAttacker`) rather
than repurposing `relayDamageEvent`. This is a correct, disclosed
resolution, not a silent miss — the file even cross-references
`server/combat.lua`'s own precedent for the same "spec text didn't survive
contact with shipped code, disclose rather than paper over" pattern.

**2. `PHASE4_SPEC.md` §13.3's file plan for `ContrabandScreenFX`.**
Confirmed: the spec table says client-side handling should be added inside
`client/search.lua`. It shipped as its own `client/screenfx.lua` instead.
The file's own header explains why: `client/search.lua` was owned by
another concurrent agent and off-limits to this pass, and `RegisterNetEvent`
supports multiple independent handlers for the same event name (the exact
"additional consumer, not a replacement" pattern already used elsewhere in
this codebase for `relayDamageEvent`/`relayWeaponFire`). Net effect: a
**strictly smaller footprint** than the spec sketched, zero changes needed
to `client/search.lua`, functionally equivalent. Correct call, well
disclosed.

**3. `COMPLEMENTARY_FEATURES.md` §7's assumption that the tenure bonus could
edit `server/wellbeing.lua`.** Confirmed: `server/tenure.lua`'s header
states plainly that every other existing file (`partnership.lua`,
`progression.lua`, `wellbeing.lua`, `movement.lua`) was off-limits for that
pass, so the bonus routes only through already-exported resource-globals
(`GetActivePartnerCitizenId`, `AwardXP`, `HasK9Access`) plus a direct
read-only `SELECT` against `k9_partnerships`. The result is narrower than
§7's "Mood regen bonus / raised Fatigue cap" suggestion — it's a one-time
flat XP milestone bonus instead of an ongoing composer input — and the file
says so itself, calling it "a downgrade forced by the file-scope boundary,"
not a design preference. Correct, disclosed, and the file even proposes
(without implementing) the one schema change (`k9_partnerships.tenure_bonus_tier_granted`)
a future pass would need to close the gap to the original §7 design — which
in fact already landed in `sql/migrations/0003_*.sql`, part of the
uncommitted work in §2.

**Verdict on all three: considered, correctly resolved, honestly disclosed.**
None of them are silent misses. The pattern across all three — "spec
assumed access/data that doesn't exist, disclose and route around it rather
than force it" — is a genuine strength of how this project's agents have
been working, not a weakness to flag.

---

## 4. Fresh documentation drift found this pass (new, not previously flagged)

`WATCHDOG_LOG.md` has caught this exact failure mode twice before (Pass #6:
`CHANGELOG.md` described a K9Inventory access control that never worked;
Pass #7: three primary docs described three shipped features as
unimplemented). **It happened again, in the very last commit:**

`4ebd078` ("Add HandlerDownDefense; close remaining client-event trust
gaps") touched `CHANGELOG.md` (337 lines) and `README.md` (448 lines) in
the same commit that added 337 lines of `client/defense.lua` and 504 lines
of `server/defense.lua`. Despite that, **neither doc's edits mention
`server/defense.lua`/`client/defense.lua`'s existence anywhere**:

- `CHANGELOG.md` has zero occurrences of `defense.lua` or any prose
  describing `HandlerDownDefense` actually being implemented — it still
  only discusses the *pre-existing* partnership-registry-as-foundation
  gap, unchanged from before this commit.
- `README.md` states, in 9 separate places verified by direct grep,
  variations of "`Config.Features.HandlerDownDefense` — still no code at
  all" and "the one Phase 3 flag left with no code at all" — all now false
  as of the same commit that edited this file.

This is the identical failure class Pass #6/#7 already named: a doc that
was accurate when written goes stale within the same commit that was
supposed to update it, because the commit's doc edits and its code changes
were evidently drafted from different snapshots. Low stakes (nobody is
misled about a *security control that doesn't exist*, just about a
feature's existence — the flag is `false` either way), but worth a
mechanical fix: grep `README.md`/`CHANGELOG.md` for `HandlerDownDefense`
and `no code at all` and correct the ~10 stale lines. This is a docs-only,
cheap fix — good candidate for whoever does the doc sync `WATCHDOG_LOG.md`
Pass #7 already recommended (its recommendation #3, still not done).

---

## 5. Externally-dependent facts — what I could re-verify this pass, and what remains open

**Egress in this environment, checked directly:** `github.com` → HTTP 400
(effectively blocked from this session), `docs.fivem.net` → HTTP 301
(redirect target not chased, treat as unreachable per prior passes'
consistent finding), `raw.githubusercontent.com` → HTTP 200, **reachable**.
`api.github.com` → HTTP 403 ("GitHub access to this repository is not
enabled for this session") — the exact same block Pass #5/#6 already
documented; still open, not a new finding.

**D6 (scent tracking's `ox_inventory` `swapItems` hook) — partially closed
this pass, with a genuine new data point.** I fetched
`overextended/ox_inventory`'s **current live `main` branch** source
directly (`modules/inventory/server.lua`, `raw.githubusercontent.com`,
reachable) and confirmed:
- `TriggerEventHooks('swapItems', {...})` is real, current, and fires from
  `dropItem` with a payload literally containing `source = source,
  toType = 'drop', ...` among other fields.
- `server/tracking.lua`'s actual hook callback reads exactly two fields off
  that payload — `payload.source` and `payload.toType` — both of which
  I independently confirmed present, spelled identically, in the live
  current source.

This is a genuinely new, direct re-verification beyond what `server/tracking.lua`'s
own "CONFIDENCE NOTE" claims (that note says the docs site — not
`raw.githubusercontent.com` — was blocked every time it was checked, and
recommends a live dev-server payload dump before trusting it). **This does
not fully close D6** — I verified the two fields this code actually reads
match the upstream source's shipping shape, not that a live install
running some other version/fork behaves identically, and I did not verify
`payload.dropId`/`fromInventory`/etc. since tracking.lua doesn't use them.
But it substantially de-risks D6: the exact two fields this resource's
production code depends on are confirmed present and correctly named in
today's canonical upstream source. I'd suggest downgrading D6 from "run a
live check before enabling" to "run a live check as a formality, not
because there's a live open question about field names" — the remaining
value of the dev-server test is confirming a *specific server's actual
installed version* behaves the same, not resolving the doc-vs-code question.

**D11 / dependency versions** — re-spot-checked `ox_inventory`'s current
`main` manifest directly: `version '2.47.9'`, matching the "last verified
compatible" figure in `DECISIONS_NEEDED.md` exactly. No drift found. Not
re-checked: `qbx_core`/`ox_lib`/`ox_target`/`oxmysql`'s versions (time
budget; `WATCHDOG_LOG.md` Pass #6 already did a thorough pass on the
maintenance-status question specifically, which is the more load-bearing
half of that claim, and resolved it well).

**`qbx_prison` dead** — not independently re-checked this pass (no new
information likely; `COMPLEMENTARY_FEATURES.md`'s citation is a direct
"Not Maintained" repo-description read, low ambiguity). Not flagging as a
risk.

**FiveM dependency-block version-pinning claim (D11)** — not independently
re-verified this pass (`github.com` itself, where the citizenfx/fivem C++
source would need to be cloned/read, was unreachable this session at HTTP
400; the original claim was made by an agent that apparently had different
or better access, or read it earlier before the block hardened). Flagging
this as **not re-verified**, not as doubted — the original claim reads as
carefully sourced (specific file names, specific constraint syntax), and
`raw.githubusercontent.com` being reachable while `github.com` proper is
blocked is a plausible asymmetry (raw file serving vs. the main site/API
gateway may be on different infra). Worth a re-check whenever `github.com`
itself becomes reachable, but I have no reason to doubt the original
finding.

**Bark-audio gap** — still open, unchanged in status, except: the
uncommitted `client/audio.lua` + `html/sounds/` (§2) appear to be the
actual attempt at the "extend the NUI bridge" path `WATCHDOG_LOG.md` Pass
#6 scoped. I did not open `html/sounds/`'s contents to confirm whether it
holds real licensed `.ogg` files or still-placeholder names — worth a
direct check by whoever picks this up next, since D7 explicitly says the
project deliberately did not fabricate or download audio, meaning
`html/sounds/` should either be empty/placeholder or externally-supplied,
not silently populated.

---

## 6. D1 — which tranche to enable first: a ranked recommendation

`DECISIONS_NEEDED.md` already frames this well and I don't disagree with
its read. Restating with my own reasoning, ranked:

**1st: the tracking/search set** (`ScentTracking`, `BloodTracking`,
`GunpowderSniffing`, `SearchZones`, `ContrabandAlerts`). This is the
correct first tranche, for three concrete reasons beyond "it's the
lowest-risk group": (a) it's **read-only with respect to other players** —
nothing about a K9 sniffing a trunk can be forced onto an unwilling
player, unlike every Category B combat effect; (b) it has now had the
**most independent verification passes** of any subsystem in this
resource — Pass #2 found and fixed 3 real bugs in it, and this pass just
added a fourth, external, upstream-source-level re-verification of its one
remaining external dependency (D6, above); (c) enabling it produces
**immediately visible, low-drama gameplay value** (a K9 that can actually
search a car) without touching any of the unresolved cross-cutting
questions (Category B enforceability, XP farming, client-relay trust) that
gate everything after it. **Caveat, unchanged from `DECISIONS_NEEDED.md`**:
flip `ScentTracking` last within this group, after the (now lower-risk,
per §5) live payload check.

**2nd: `HandlerPartnership` alone, without anything downstream of it yet.**
This isn't in `DECISIONS_NEEDED.md`'s explicit ranking but I'd put it here
because it's structurally different from every other still-off flag: its
own header states it "wires no combat consequence of its own," and I
confirmed that's still true even after `HandlerPartnership`'s TOCTOU fix
landed (`88b3b89`) — establishing a partnership changes nothing about
gameplay except letting two players see each other as "partnered." It is
close to risk-free to enable on its own, and doing so *before* combat is
enabled means the partnership registry accrues real production data
(tenure, `established_at`) that `PartnershipTenureBonus`/`HandlerDownDefense`/`Recall`
can immediately benefit from once those are ready, rather than starting
from zero the day combat goes live.

**3rd, and only after real playtest data from the above: Phase 4's
non-HUD items** (`K9Inventory`, `K9Medkit`, wellbeing stats), because
`HealthStaminaHUD` and `XPProgression` genuinely need player-facing data
(what does a real handler's fatigue/mood curve look like) that only comes
from having players actually playing K9s under tranche 1, and because the
`DECISIONS_NEEDED.md` D4/D5 numeric defects (dead scent-range bonus,
farmable contraband XP) should be fixed **before**, not after, XP starts
accruing on a live server — retroactively re-balancing already-earned XP
is a worse conversation to have with players than fixing the numbers
pre-launch.

**Last, and only with eyes fully open per D2: Category B combat**
(`BiteAndHold`, `NonLethalTakedown`, `PropDragging`). I have nothing to add
to `DECISIONS_NEEDED.md`'s framing of D2 — it's correct that this is an
inherent FiveM entity-authority limitation, not a code defect, and there is
genuinely no third option. I'd only add: the client-relay trust boundary
(D3) is graded "medium-high, not certain" by the project's own admission,
and combat is the one tranche where that grading actually matters (a
false sense of security here has real gameplay-integrity cost, not just a
cosmetic one). Don't enable any Category B flag until D3 gets its
recommended in-engine confirmation, independent of whatever else gates it.

---

## 7. What's genuinely at risk — specific, not softened

1. **The uncommitted working tree (§2) is the single biggest concrete risk
   in this project right now**, ahead of anything code-level. Ten files of
   apparently-complete feature work (Recall, the export surface, the admin
   surface, the tenure bonus, three SQL migrations) exist nowhere except
   this one working directory. A `git status` accident, a container
   restart without a volume, or an unreviewed `git checkout .`/`git clean
   -fd` would destroy hours of disclosed, well-reasoned engineering work
   with no way to recover it from history. This should be committed (even
   if not yet wired into `fxmanifest.lua`/`.luacheckrc`, which the owner
   reserves) at the owner's very next opportunity.

2. **The flag-off-safety defect class has now recurred at least twice in
   one session** (`client/combat.lua`'s original fix, then three more
   instances Pass #7 found in `kennel.lua`/`medkit.lua`/`progression.lua`).
   `WATCHDOG_LOG.md` Pass #7 already recommended a repo-wide convention
   check (a grep-based rule: every `client/*.lua` `RegisterNetEvent` handler
   must reference its owning `Config.Features` flag somewhere in its own
   body or an enclosing file-scope guard). **I did not re-verify whether
   this recommendation was acted on**, and I did not re-run the full sweep
   against the newest files (`defense.lua`, `recall.lua`, `screenfx.lua`,
   `audio.lua`) this pass — given the pattern's proven recurrence rate,
   I'd treat this as a near-certain place to find a fourth instance, and
   recommend it as the very next security-focused task, ahead of enabling
   anything.

3. **The `.luacheckrc`/`fxmanifest.lua`/`config.lua` ownership change is a
   process risk, not a code risk, but a real one.** Every prior watchdog
   pass and this session's own commit history shows these three files
   being routinely edited by implementing agents as a normal part of
   landing a feature (new global names in `.luacheckrc`, new files in
   `fxmanifest.lua`, new flags in `config.lua`). The instruction that
   "the user owns these three now" is a genuine workflow change that
   nothing in `DECISIONS_NEEDED.md`/`WATCHDOG_LOG.md` reflects yet — it
   directly explains why 8+ files of otherwise-complete work (§2) are
   currently inert. Whoever resumes this project needs a clear handoff
   protocol (does an agent draft the manifest/config/luacheckrc diff for
   the owner to apply, or wait for the owner to do it themselves?) or this
   bottleneck will keep growing.

4. **Category B combat's fundamental limitation (D2) is real and will
   surface as a player complaint, not a bug report, if anyone forgets it's
   a property of the platform.** Not new, but worth restating plainly since
   the task asked for honesty here: no code change fixes this. A modified
   client's owner will discover the bite-hold ignores them, and the correct
   response is "yes, that's expected, here's why," not a support ticket
   treated as a bug.

5. **The contraband-search XP farm (D5) is a live economic exploit the
   moment `SearchZones`+`ContrabandAlerts`+`XPProgression` are all enabled
   together**, even though each is individually reviewed as safe. This is
   exactly the kind of interaction-between-independently-correct-pieces
   risk this role is meant to catch: `SearchZones` alone is safe,
   `XPProgression` alone is safe, but their *composition* — real,
   deterministic search results plus a 10-second cooldown and no
   anti-farm floor — reaches the top XP tier in under half an hour with a
   suspect's own trunk and zero travel. If tranche 1 (§6) and tranche 3
   ever go live together without D5 being resolved first, this is the
   first exploit a player will find. Sequence D5's fix before, not after,
   enabling both flags simultaneously.

6. **Nobody has re-run the whole-tree `flag-off safety sweep`
   (WATCHDOG Pass #7's method) against the five newest files** —
   `defense.lua` (both halves), `recall.lua` (both halves), `screenfx.lua`,
   `audio.lua`, `admin.lua`, `exports.lua` (both halves), `tenure.lua`.
   Given finding #2 above, this is unverified, not verified-clean by
   omission — I did not have time in this pass to do it myself and want to
   be explicit that "not mentioned as broken" here should not be read as
   "checked and fine."

---

## 8. What I could not verify from this read-only pass

- Whether `html/sounds/`'s actual file contents are real licensed audio or
  still placeholders (didn't open the directory's file contents).
- Whether the flag-off-safety sweep passes on the six newest uncommitted
  files (risk #6 above — genuinely unknown, not assumed clean).
- The FiveM engine's dependency-version-pinning claim (D11) — `github.com`
  itself was unreachable this session to re-clone/re-read the C++ source;
  I have no reason to doubt the original finding but did not re-derive it.
- Whether anyone else is concurrently editing `fxmanifest.lua`/`config.lua`/
  `.luacheckrc` right now, given this is one of ~20 parallel agents on this
  repo.
