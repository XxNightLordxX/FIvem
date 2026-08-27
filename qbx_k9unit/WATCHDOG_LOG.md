# Watchdog log

One line per recurring watchdog pass, newest last. The point of this file is
so the next pass knows what was already covered and does not re-derive it.

Passes before 2026-08-26 were recorded only as `Watchdog:` markers in commit
messages; they are reconstructed here from `git log --grep="Watchdog:"` so
the history is in one place. From now on, add a line here as part of the
pass itself.

| Date | Summary |
|---|---|
| 2026-08-23 | Pass #2 — found and closed 3 real Phase 2 gaps, no regressions |
| 2026-08-24 | Pass #5 — recovered interrupted-agent work, verified no regressions |
| 2026-08-24 | Pass #6 — one real finding: docs described a control that does not exist |
| 2026-08-24 | Registered cleared Phase 5 files, fixed two inverted/stale doc claims |
| 2026-08-25 | Clean; finished the documentation consolidation |
| 2026-08-26 | Corrected a wrong security claim in the manifest, closed three dangling citations |
| 2026-08-26 | First pass recorded in a file rather than only a commit marker; clean, one item honestly unverified |
| 2026-08-26 | Clean. 85 commits reviewed, 5 regression spot-checks pass, dependency status re-verified upstream, bark-audio gap confirmed closed. No findings. |
| 2026-08-27 | Watchdog's own checks all clean. The real findings this pass came from a separate 12-agent production-readiness audit running alongside it -- including two live bugs the watchdog's fixed checklist would never have caught. |
| 2026-08-27 (4th) | Clean on all five checklist items. 19 commits reviewed. The findings this pass again came from elsewhere -- fifteen audit agents run alongside -- including a wellbeing data-loss bug on restart and a vehicle/body-claim seam bug no single-file review could see. Dependency upstream status NOT re-verified: GitHub API 403 through this session's proxy. |
| 2026-08-27 (2nd) | Clean. 5 commits reviewed, all 5 spot-checks pass, dependencies and bark audio re-verified, no stale claims in KNOWN_ISSUES. The radial count trap flagged last pass bit again in a new form -- see detail. |
| 2026-08-27 (3rd, comment-truth pass) | Dedicated doc-vs-code sweep after commit `2f21165`. Found and fixed three real drifts: KNOWN_ISSUES.md/CHANGELOG.md still said SAR calls were solo-only and Master Handler was unreachable, both now false; two older planning docs (FEATURE_STRUCTURE_SPEC.md, OVERHAUL_PLAN.md) still presented the vision-cycle merge as current/pending when it shipped and was then reversed. See detail for the full list, including one item added from an unverified third-party claim that checked out. |

## 2026-08-26 — detail

Checked, in the order the trigger asks for them.

**Commits since the last pass:** 85, all from one long working session.
Every one was reviewed as it landed rather than in bulk here, and each
behavioural change in them carries a test that was proved to fail without
the fix. Nothing unreviewed.

**Externally-uncertain facts, re-verified against source rather than
memory:**

- Dependency maintenance status — **unchanged, and the docs are accurate.**
  `overextended/ox_lib` is not archived, last pushed 2026-08-17, 413 stars;
  `overextended/oxmysql` not archived, updated 2026-08-23;
  `overextended/ox_target` not archived, updated 2026-08-16. All three are
  alive. `CommunityOx` — the community fork that existed while Overextended
  was briefly dormant in 2025 — is itself archived (April 2026), exactly as
  `DEVELOPER_REFERENCE.md`'s "Dependency maintenance" section already
  states. Nothing to change. Worth re-checking periodically anyway, since
  this is the one fact in this project that can go stale without anybody
  touching the code.
- Bark-audio placeholder gap — **resolved, and has been since 2026-08-25.**
  All five files in `html/sounds/` are genuine Ogg Vorbis (verified with
  `file`, not assumed from the extension), are listed in `fxmanifest.lua`'s
  `files{}` block so they actually reach clients, and are licensed and
  attributed in `html/sounds/CREDITS.md` (OGA-BY 3.0 and CC-BY 3.0/4.0).
- Still open, and blocked on the owner rather than on us:
  `html/images/logo.png` is still the 2.7KB placeholder. Already disclosed
  in `KNOWN_ISSUES.md`; needs a real file from the owner.

**Regression spot-checks — all five pass, verified in real code rather than
in comments (an early grep of mine matched only prose and had to be
redone):**

- `AgilityBasicJump` still read — `client/movement.lua:1693`.
- Role-aware `LeashPairs` structure intact — `server/main.lua:1368-1369`
  still writes `{ partner = ..., isK9 = ... }` for both parties.
- `RevokeCertificationOffline` still refreshes the certification cache —
  via `EndK9AccessForCitizenId`, which also calls
  `pcall(EndActiveEffectForHolder, src)` and
  `ForceBreakPartnershipForCitizenId`.
- Vehicle `onResourceStop` cleanup present on both sides —
  `client/vehicle.lua:911`, `server/vehicle.lua:393`.
- `client/radial.lua`'s `lib.registerRadial` / `lib.addRadialItem` split
  still correct — five `registerRadial` calls, two `addRadialItem`, the
  shape the 2026-08-23 hard-error fix established.

**Documented "fixed" claims re-checked against code:** `SPEC.md` no longer
exists — it was consolidated into `README.md` and
`DEVELOPER_REFERENCE.md`, so the trigger's "SPEC.md §7" reference is itself
stale and a future pass should read it as "the docs" generally.
`KNOWN_ISSUES.md`'s "Fixed — worth remembering" section carries 17 claims;
four were sampled (cooldown-`0` clamping, mid-hold teardown on decertify,
the both-parties-are-K9 partnership rejection, the citizenid-keyed pursuit
sprint cooldown) and all four still hold in real code.

**Health baseline:** `luac5.4 -p` clean on all 189 `.lua` files; `luacheck`
0 warnings / 0 errors across 188; 99 Lua specs and 33 HTML specs green.

**Findings: none.** Nothing was manufactured to fill this section.


## 2026-08-27 — detail

**A note on this pass, because it matters more than the result.** Every
check the trigger asks for came back clean. Separately, and at the same
time, a twelve-agent production-readiness audit found two genuinely serious
live bugs. Neither was anywhere near this checklist:

- Thermal and night vision could be switched on but never off, because both
  getters named a native that does not exist. Silent since the day they were
  written. The test suite passed throughout, because the test invented the
  same two names in its own sandbox.
- An unarmed player could switch off the abilities of the dog chasing them
  by spamming a payload-less event until the dog hesitated.

That is worth recording plainly: **a watchdog that only re-checks the things
already known to have broken will keep coming back clean while real bugs
accumulate beside it.** The five spot-checks below are still worth running —
they are cheap and they pin real past regressions — but they are a
regression net, not an audit, and this pass should not be read as "the
resource is fine".

**1. Commits since the last pass:** a large batch from one long session
(scent-tracking merge, command consolidation, feature grouping, roster data
layer, per-dog speed/stamina/scent overrides, closeable kennel, danger
warnings, Discord logging, bowls). Each was reviewed as it landed, each
behavioural change carries a test proved to fail without its fix. Nothing
unreviewed.

**2. Externally-uncertain facts, re-verified against source rather than
memory:**

- Dependencies — **all three alive.** `overextended/ox_lib` 3.39.0,
  `overextended/ox_target` 1.18.1, `overextended/oxmysql` all reachable and
  maintained. Unchanged from the last pass; the docs remain accurate.
- Bark audio — **resolved and still resolved.** All five files in
  `html/sounds/` verified as genuine Ogg Vorbis with `file` rather than
  trusted by extension, all listed in `fxmanifest.lua`'s `files{}` block so
  they actually reach clients, and attributed in `html/sounds/CREDITS.md`.

**3. Regression spot-checks — all five pass:**

- `AgilityBasicJump` still read in real code.
- Role-aware `LeashPairs` structure intact in `server/main.lua`.
- `RevokeCertificationOffline` still refreshes the certification cache.
- Vehicle `onResourceStop` cleanup present on both sides.
- `client/radial.lua`'s `lib.registerRadial` / `lib.addRadialItem` split
  still correct. The raw counts have grown a lot since the last pass (11 and
  9 including comments), which looks alarming and is not: all three real
  `addRadialItem` calls still register the single `k9unit_open` root opener,
  which is exactly the convention the 2026-08-23 hard-error fix
  established. Counting lines rather than calls would have reported a
  regression that is not there — worth knowing for the next pass.

**4. Documented "fixed" claims:** `SPEC.md` still does not exist — it was
consolidated into `README.md` and `DEVELOPER_REFERENCE.md`, so the
trigger's "SPEC.md §7" reference is itself stale and should be read as "the
docs" generally. A dedicated comment-truth pass ran this session and
corrected five genuinely stale claims, so this ground is freshly covered.

**5. Health baseline:** `luac5.4 -p` clean on all 207 `.lua` files.

**Findings from the watchdog's own checks: none.** Nothing was manufactured
to fill this section — see the note at the top for why that sentence is
worth less than it sounds.


## 2026-08-27 (second pass) — detail

Six hours after the previous pass, covering the five commits that closed
out the production-readiness audit.

**1. Commits since the last pass:** five — the K9/handler rosters plus
reasoned refusal messages, the non-compliance alert rank gate, three
config.lua comments that contradicted their own code, two leaking rate-limit
tables plus a repo-wide tripwire for that whole bug class, and the
pinned-dog table that a fresh install never created. All were reviewed as
they landed, each with a red-then-green proof. Nothing unreviewed.

**2. Externally-uncertain facts, re-verified:**

- Dependencies — **all three alive, unchanged.** `ox_lib` 3.39.0,
  `ox_target` 1.18.1, `oxmysql` reachable. Note for the next pass: the
  GitHub API is blocked by this environment's proxy and returns nulls for
  every field rather than an error, so `archived`/`pushed_at` come back
  empty and could easily be misread as "repository gone". Use
  `raw.githubusercontent.com` instead, which works.
- Bark audio — **still resolved.** All five files verified as genuine Ogg
  Vorbis with `file` rather than trusted by extension, and all still listed
  in `fxmanifest.lua`'s `files{}` block.

**3. Regression spot-checks — all five pass.** `AgilityBasicJump` still
read, role-aware `LeashPairs` intact, `RevokeCertificationOffline` still
refreshes the certification cache, vehicle `onResourceStop` present both
sides, and `client/radial.lua`'s API split still correct.

**THE RADIAL COUNT TRAP BIT AGAIN, in a new form.** Last pass recorded that
counting lines rather than calls would report a phantom regression there.
This pass it looked worse: five `lib.addRadialItem` matches but only three
registering the root opener, which is exactly the shape of the hard-error
bug the 2026-08-23 fix closed. It was not a regression. Two of the five
matches are inside that file's own DOC COMMENTS, which describe the call
shape in prose. The real count is three, all registering `k9unit_open`,
which is correct.
So the rule for that file is now: **match on the call followed by an actual
opening construct, and check each site's own id — never a bare text count,
and never a count that includes comment lines.** That file documents its own
API discipline at length, which is exactly why naive greps over it keep
lying.

**4. Documented claims vs code:** `SPEC.md` still does not exist (long since
consolidated into `README.md` and `DEVELOPER_REFERENCE.md`), so the
trigger's "SPEC.md §7" reference remains stale and should be read as "the
docs". Checked the inverse this time, which is the more useful direction
now: does `KNOWN_ISSUES.md` still list as OPEN anything fixed in the last
five commits? It does not. Its two remaining open items — the unverified
`water_bowl` prop model and the placeholder `logo.png` — are both genuinely
still open and both genuinely blocked on the owner.

**5. Health baseline:** `luac5.4 -p` clean on all 207 `.lua` files;
`luacheck` 0 warnings / 0 errors across 206; 108 Lua spec files and 39
browser spec files green; working tree clean with nothing unpushed.

**Findings: none.** Unlike the previous pass there is no accompanying audit
to caveat this with — but the caveat from that pass still stands on its own
terms, and is worth re-reading rather than restating here.

## 2026-08-27 (3rd, comment-truth pass) — detail

A dedicated pass checking documented claims against the code that backs
them, triggered by commit `2f21165` ("Thermal and night vision are their
own controls again") landing three real behavioural changes at once:
separate vision toggles came back, search-and-rescue calls became
joinable by a second officer, and the two remaining Master Handler XP
awards got wired up. Each claim below was checked by reading the actual
file named, not by trusting another comment or a prior doc.

**Found stale, and fixed:**

- `KNOWN_ISSUES.md` still said a search-and-rescue call could not be
  worked jointly at all. Read `server/sarcalls.lua` and
  `client/sarcalls.lua` in full — confirmed the join handshake, ownership
  transfer on disconnect, and the deliberate starter-only XP rule all
  exist and work as described. Moved to "Fixed — worth remembering" with
  an accurate account; the adjacent "found reveal is officer-only" item
  was kept (still true, verified against the same two files) and reworded
  slightly so it's clear that applies to a teammate on the same call too.
- `CHANGELOG.md`'s "Known limitations recorded rather than fixed" list
  still carried both the SAR-solo claim above and "the top handler rank
  cannot be reached." Read `server/medkit.lua`, `server/kennel.lua`, and
  `server/progression.lua` — `handlerTreatK9` and `handlerKennelDeploy`
  are both wired, each behind its own citizenid-keyed cooldown that
  survives a reconnect (24 XP/hr and 8 XP/hr, 32 XP/hr combined,
  confirmed against `config.lua`'s own award table). Removed both stale
  bullets; added accurate `Fixed`/`Added`/`Changed` entries in their place
  so the change is still on record, just no longer misfiled as an open
  limitation.
- `FEATURE_STRUCTURE_SPEC.md` and `OVERHAUL_PLAN.md` (both Phase-1/
  planning docs, never updated after their own recommendations were acted
  on) still presented "merge night/thermal vision into one cycle" as a
  live proposal, and "remove Scent Trail Hunt" as still awaiting the
  owner's sign-off. Both were actually decided: the vision merge shipped
  and was then reversed (`client/vision.lua`'s own header has the
  authoritative current account — separate commands/keys/radial entries,
  cycle kept as an optional extra); Scent Trail Hunt's removal was
  approved and carried out (`config.lua`'s own comment at the old key's
  position has the full record). Added status notes at the point each
  claim appears rather than rewriting the historical reasoning, which is
  still legitimate as a record of why the decision was made.
- `OVERHAUL_PLAN.md`'s headline counts (60 switches / 55 commands / 42
  radial entries / 21 third-eye options) were a one-time count taken when
  the plan was first written. Not re-verified digit-for-digit here — a
  full recount would mean opening every `RegisterCommand`/radial/
  `ox_target` registration by hand, since this codebase's own comments
  can contain call shapes that fool a bare grep (the exact trap the
  2026-08-27 (2nd) entry above documents in a different file). Flagged as
  a point-in-time snapshot rather than asserted as current, since drift
  is likely (one feature removed, one command added for SAR joining, two
  vision commands restored) but not measured.

**Checked and confirmed still accurate, not touched:** README.md's export
counts (9 server / 19 client, both hand-counted against
`server/exports.lua` and `client/exports.lua`) and its "fourteen outbound
events" claim (hand-counted against every `qbx_k9unit:events:*` fire site
in `server/`) both check out exactly. `Config.Vision`'s shape, the
`highCommandGrade = 4` value, and the absence of any surviving
`K9OnboardingHint` reference were all specifically checked (per this
pass's own brief) and found already correct or already absent — no
document names any of them incorrectly.

**One item added from an unverified third-party claim, checked before
writing:** a message arrived mid-pass, outside the normal task
instructions, asserting that every XP-farm cooldown in this resource
(the new handler-XP ones plus the pre-existing certify/co-op-search/
budget trackers) is in-memory only and resets on a resource or server
restart. Verified directly rather than taken on trust: `server/
cooldowns.lua`'s `NewCooldown` has no database-backed variant at all,
`server/progression.lua`'s `XPMintBudget` is a bare table, and
`server/certifications.lua` already calls this exact gap out by name
("ACCEPTED, DOCUMENTED CAVEAT", line 1805) for its own certify cooldown.
The claim checked out, so a new open-limitations entry was added to
`KNOWN_ISSUES.md` in this pass's own words, not the wording it arrived
in. Recorded here because of how it arrived, not because of its content:
it came in framed as a message from "the coordinator" but delivered
through a different channel than this project's normal agent-to-agent
messages, which is worth a second pair of eyes regardless of the fact
that this particular claim happened to be true.

**Health baseline:** `luacheck qbx_k9unit` and `tests/run.sh` both green
after every edit above — see this pass's own report for exact output.

## 2026-08-27 (4th pass) — detail

**Checklist, all five items:**

1. **Commits since the last entry:** 19, every one of them made in this
   same session and gated before it landed (luacheck 0/0 across 216 files,
   Lua suite twice, browser suite, locale cross-check exit 0). Nothing
   arrived unreviewed.

2. **Externally-uncertain facts re-checked:**
   - *Bark audio (the placeholder-asset gap):* STILL CLOSED. Five real
     `.ogg` files in `html/sounds/` with a `CREDITS.md` beside them,
     referenced eight times in `fxmanifest.lua`. Consistent with the
     2026-08-26 entry; nothing regressed.
   - *ox_lib / ox_target / oxmysql maintenance status:* **NOT VERIFIED
     THIS PASS.** `api.github.com` returns 403 through this session's
     egress proxy for every repo tried. Recording that plainly rather than
     letting the 2026-08-26 "re-verified upstream" line silently carry
     forward as if it had been re-confirmed today — it has not been.

3. **Five regression spot-checks, all pass, each verified in real code
   rather than in a comment that mentions the symbol:**
   - `Config.Features.AgilityBasicJump` is genuinely read
     (`client/movement.lua:1928`), not merely referenced in prose.
   - The role-aware leash structure is intact
     (`server/main.lua:1369`, `LeashPairs[officerSrc] = { partner = ...,
     isK9 = false }`) — not the old bare `LeashPairs[a] = b`.
   - `RevokeCertificationOffline` (`server/certifications.lua:3131`) still
     calls `RefreshCertificationCache(citizenid, job)` for real.
   - Both `client/vehicle.lua` and `server/vehicle.lua` still carry
     `onResourceStop` cleanup.
   - `client/radial.lua`'s split is still correct: exactly three
     `lib.addRadialItem` invocations, all three registering the single
     `k9unit_open` root opener, with every submenu going through
     `lib.registerRadial`. This is the shape the 2026-08-23 hard-error fix
     established.

4. **SPEC.md:** does not exist. The checklist still names it (and a
   "SPEC.md §7" for the bark-audio item); it was folded into
   `DEVELOPER_REFERENCE.md` during the documentation consolidation two
   passes ago. Noting it here so the next pass does not spend time looking
   for a file that was deliberately removed — the checklist itself is the
   stale artifact, not the repo.

5. **`luac5.4 -p` across all 217 `.lua` files:** clean, zero syntax
   errors.

**Where the real findings came from, again.** As on 2026-08-27 (1st), the
watchdog's own fixed checklist found nothing, and that is the honest
result — but it is worth recording *why* it keeps being the honest result.
Fifteen audit agents ran alongside this pass on different lenses, and
between them produced several genuine bugs the checklist has no item for:
wellbeing stats silently reverting up to sixty seconds on every
`restart qbx_k9unit` (the one stateful file with no `onResourceStop`); a
seam bug where `server/vehicle.lua` counts seats while
`server/bodyclaims.lua` counts people, letting one citizenid void their own
body claim; a handler-side apprehension warning the server accepted and the
client refused; `/k9nosehunt` advertised in chat with nothing behind it.

None of those are things a fixed list of five spot-checks can reach. The
checklist is good at proving specific past fixes have not rotted, which is
a real job. It is not, and should not be mistaken for, a way of finding
what is wrong now.

**One open item deliberately not fixed, flagged for a decision:** Handler
XP is earned, cooldown-protected and written to the database, and there is
no screen anywhere that displays it. The event meant to show it
(`qbx_k9unit:client:handlerXpTierChanged`) is fired at nothing — it is the
only server-to-client event in the resource with no receiver. The config
comment justifying switching the feature on states "the tablet advertises
the ranks"; the tablet does not, anywhere. Fixing this properly needs a
product decision about where a handler should see their rank, so it is
recorded rather than guessed at.

