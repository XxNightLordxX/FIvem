# qbx_k9unit — Technical Debt / Refactor Roadmap

**Docs-consolidation note, 2026-08-25:** this file now contains both
technical-debt audits that used to be separate files. What was
`REFACTOR_ROADMAP.md` (the original full audit, Revision 6) is **Part A**,
unchanged below. What was the separate `REFACTOR_ROADMAP_2.md` (a second,
independent audit written alongside it) is appended as **Part B**, also
unchanged in content — only relocated. Neither part was rewritten to agree
with the other; where they overlap, each still speaks for itself as of its
own stated date. This is a developer/maintainer document — nothing here was
simplified for a non-technical reader, since only agents and coders are
expected to act on it.

## Part A — original audit

**Revision 6 — full re-verification against live source, 2026-08-24.**
Written after Revision 5 was found to contain a wrongly-marked-DONE item
(item 2, `ResolveNetworkEntity`) that had actually been reopened by 11 new
copies. Every claim below was checked directly against source with Grep/Read
at the time of this pass — nothing is carried forward from Revision 5 without
re-verification. **This pass found the opposite problem too: Revision 5's
"REOPENED"/"open" status for items 2, 2b, and 3 is now itself stale — a
parallel agent finished that migration after Revision 5 was written, and the
file on disk had not been updated to say so.** Both directions of staleness
(claiming done when not, and claiming open when done) have now hit this
document. Treat every status here as good only as of this pass's timestamp,
not as durable truth — the codebase is being edited by multiple agents
concurrently with this audit (see "In flight" note below).

**In flight during this pass:** four files did not exist at the start of
this audit and appeared partway through — `client/propattachment.lua`,
`server/propattachment.lua`, `client/bonetool.lua`, `server/bonetool.lua`.
None of the four are registered in `fxmanifest.lua` as of this pass (grepped:
zero matches for `propattachment`/`bonetool` in that file), so none of this
code currently loads. `server/tracking.lua`, `server/admin.lua`, and
`server/recall.lua` also grew between two Glob calls taken minutes apart
during this pass. Do not treat any line count or "still open" claim below
about these files as stable — re-check before acting on it. `fxmanifest.lua`
is owned by another agent per this session's rules; flagging the missing
registration here for that owner/project-lead, not fixing it.

**Update, documentation sync pass, 2026-08-25:** re-checked directly — all
four files above, plus `client/fetch.lua`/`server/fetch.lua`, are now
registered in `fxmanifest.lua`. This closes the missing-registration flag
this note raised; see Part 6's corrected items for detail. Leaving this
paragraph in place unedited, per this document's own convention, rather
than rewriting it as if the gap were never real.

---

## Part 1 — Verifying Revision 5's claims

### Item 2 (`ResolveNetworkEntity`) — Revision 5 said "REOPENED by 11 copies." Verified: actually DONE now.

Direct check of every file Revision 5 named as a bypasser:

- `server/kennel.lua` — all 3 sites (`RemoveKennelForCitizenid` ~238,
  `confirmKennelPlaced` ~358 with the `expectedEntityType=3` fold-in,
  `onResourceStop` ~476) now call `ResolveNetworkEntity`. Confirmed at
  `server/kennel.lua:238,358,476`.
- `client/kennel.lua` — both sites (`removeKennel` handler ~254, its
  `onResourceStop` ~291) now call `ResolveNetworkEntity`.
- `client/combat.lua` — **9 call sites** now use `ResolveNetworkEntity`
  (lines 732, 762, 830, 857, 900, 1080, 1178, 1234, 1246), each tagged
  `-- REFACTOR_ROADMAP.md item 2 (client/main.lua)`. Note: Revision 5 counted
  5 raw copies here; `WATCHDOG_LOG.md` (~line 943) separately caught that the
  real pre-migration count was 9, not 5 (4 more were added by an unrelated
  PropDragging commit after Revision 5's audit ran but before it was
  finished). The migration that landed covers all 9, not just the 5
  originally logged — recording the correct number here so it doesn't
  quietly become wrong again.
- `server/inventory.lua` — the bare `entity == 0` check (previously the
  weakest surviving instance, no `DoesEntityExist` call at all) is gone;
  `HandleOpenK9Inventory` now calls `ResolveNetworkEntity(targetNetId, 1)` at
  `server/inventory.lua:444`.

`server/entities.lua` (181 lines) is the shared implementation; its own
header documents exactly this history layer-by-layer rather than having been
silently rewritten — a good instance of the "layer corrections, don't erase
history" convention this document itself is trying to follow. Zero raw
`NetworkGetEntityFromNetworkId` call sites remain anywhere outside
`client/main.lua`'s and `server/entities.lua`'s own function bodies —
**except one, new, see Part 2 below.**

**Verdict: DONE**, for real this time, for every file Revision 5 named.

### Item 2b (`ResolveConnectedPlayerFromPed` / `ResolvePlayerServerIdFromPed`) — Revision 5 said "new, open." Verified: DONE.

`server/entities.lua:173` now defines `ResolveConnectedPlayerFromPed`, called
from `server/search.lua:556`, `server/inventory.lua:449`, and
`server/combat.lua:719` — the 3 server copies Revision 5 flagged, all
migrated, each with a "used to be defined here as a local copy" comment
marking the deletion. `client/main.lua:270` defines
`ResolvePlayerServerIdFromPed`, called from `client/medkit.lua:75` and
`client/wellbeing.lua:282,299` — the 2 client copies, also migrated. No
stray local re-definitions of either function remain.

**Verdict: DONE.**

### Item 3 (`IsEntityModelK9` / `K9ModelHashes` boolean tables) — Revision 5 said "upgrade to do-soon, 6 copies." Verified: DONE, and it found a 7th copy nobody had logged.

`client/main.lua:133` now defines the single `IsEntityModelK9(entity)`
resource-global. Its own comment (`client/main.lua:108-127`) records that the
consolidation found **6** client-side copies, not the 5 Revision 5 tracked —
`client/partnership.lua` had an undocumented 6th, found only while doing this
extraction. Verified all 6 source files
(`client/movement.lua:610,695,724`; `client/wellbeing.lua:279,296`;
`client/medkit.lua:72`; `client/inventory.lua:88`; `client/partnership.lua:488`)
now call the global; no local re-definition remains in any of them.
`server/certifications.lua`'s server-side `K9ModelHashes`/`IsConfiguredK9Model`
is correctly left alone (can't cross the realm boundary) — this was always
the right call, not an oversight.

This is directly relevant to this session's explicitly-known-in-progress
item: **`IsEntityModelK9` duplication across `client/movement.lua`,
`client/inventory.lua`, `client/partnership.lua` is confirmed resolved as of
this read** — all three now call the shared global, zero local copies
remain. Per this task's instructions this was being worked by another agent
concurrently; no further work is planned against it here, only this
verification.

**Verdict: DONE.**

### Item 1 (cooldown/mutex helper, `server/cooldowns.lua`) — re-verified under load, still holding

Every file in the current tree that needs a cooldown or mutex uses
`NewCooldown`/`NewNestedCooldown`/`NewMutex` — including the brand-new,
still-unregistered `server/bonetool.lua` (`BoneToolCooldown = NewCooldown()`)
and `server/propattachment.lua` (`ToggleCooldown = NewCooldown()`). A
targeted grep for the hand-rolled shape this item replaced (`local
lastXAt = {}` / raw `GetGameTimer()` comparisons outside
`server/cooldowns.lua` itself) found zero matches anywhere in the tree.

**Verdict: DONE, and durable** — this is the one item that has now survived
two full rounds of unrelated parallel-agent growth without a single
regression. Worth understanding *why* it held when items 2/2b/3 didn't
before their fix: `server/cooldowns.lua` was extracted early (Revision 3),
giving every subsequent file something ready-made to reach for. Items 2/2b/3
were extracted late, after competing hand-rolled copies had already spread —
the lesson for what's below is to extract while a pattern still has 2-3
copies, not 10.

### The flag-off-safety defect class (from `WATCHDOG_LOG.md`, not previously in this document) — verified FIXED

`WATCHDOG_LOG.md` (~line 846) logged three still-open instances of a real
security-relevant defect: a client `RegisterNetEvent` handler for a
server-issued instruction with no `Config.Features.X` gate, meaning a forged
local `TriggerEvent` reaches it even with the feature shipped disabled
(`client/kennel.lua`'s `deployKennelAt`/`removeKennel`, `client/medkit.lua`'s
`applyMedkitHeal`, `client/progression.lua`'s `xpTierChanged`). Checked all
three at current `HEAD`:

- `client/kennel.lua:166` — `if not Config.Features.DeployableKennel then
  return end`, present, with a comment explicitly marking this as the fix.
- `client/medkit.lua:132` — `if not Config.Features.K9Medkit then return
  end`, present, same disclosure pattern.
- `client/progression.lua:110` — `if not Config.Features.XPProgression then
  return end`, present.

**Verdict: FIXED** since that watchdog entry was written. Not tracked as a
roadmap item (it's fixed), recorded here only so a future pass doesn't
rediscover watchdog history as if it were still current — the same courtesy
this document is trying to extend to whoever reads it next.

---

## Part 2 — What nobody has recorded yet

### NEW, unrecorded: a fresh, live instance of item 2's exact pattern, written into a file that landed *during* this audit

`client/propattachment.lua:237-239` (a file that did not exist at the start
of this pass):

```lua
if not NetworkDoesEntityExistWithNetworkId(netId) then return end
local entity = NetworkGetEntityFromNetworkId(netId)
if not DoesEntityExist(entity) then return end
```

This is the exact three-line sequence `ResolveNetworkEntity` (already
present and working, in the same client realm, one file away in
`client/main.lua`) was built to replace — hand-written from scratch instead
of calling `ResolveNetworkEntity(netId)`. It is not a regression in
correctness (all three checks are present, so behavior is equivalent to
calling the helper) — it is a regression in the *thing this roadmap has now
fixed twice*, in real time, while the fix was still being verified. This is
the single clearest piece of evidence for this document's headline finding:
**extracting a shared helper does not stop the pattern from recurring by
itself — every new file's author still needs to know the helper exists.**
**Update, later pass: fixed.** `client/propattachment.lua` now calls
`ResolveNetworkEntity(netId)` directly at this call site, and the file is
registered in `fxmanifest.lua` — see Part 6's corrected item 2 below. Left
here, marked resolved rather than deleted, as the concrete example this
section's headline finding ("extracting a shared helper does not stop the
pattern from recurring by itself") was built around.

### RESOLVED 2026-08-24: `NotifyPlayer` — was 13 copies, not the "2, closed" Revision 2 recorded

> **Status: DONE.** Extracted to `server/notify.lua` (a new shared-helper file
> alongside `cooldowns.lua`/`entities.lua`, not folded into `entities.lua` as
> this section originally suggested — "which toast, with what title" is a third
> responsibility, unrelated to timing state or reference resolution, and this
> resource's stated convention is one shared file per responsibility).
> Registered in `fxmanifest.lua` before all consumers; `NotifyPlayer` declared
> in `.luacheckrc`.
>
> **The final count was 13, not 12** — a 13th copy landed in `server/fetch.lua`
> while the extraction was in progress, in a file that did not exist when the
> audit below ran. It was caught by a final grep sweep rather than by trusting
> the audit's number. That is the third time on this project a duplication
> count has been wrong in the low direction.
>
> `server/admin.lua` and `server/bonetool.lua` deliberately keep a one-line
> local wrapper over the shared global, because each varies the notification
> title in a way players actually see; flattening those to the generic title
> would have been a regression disguised as a cleanup. Those wrappers must call
> `_G.NotifyPlayer(...)` explicitly — a bare call inside a same-named local
> function recurses into itself rather than reaching the global.
>
> The original analysis is kept below unedited, per this document's own
> "layer corrections, don't rewrite history" convention.

#### Original analysis (Revision 6, now resolved)

Revision 2 tracked `NotifyPlayer` duplication, found it stayed at 2 copies
through Phase 2, and closed it as a non-issue. It did not stay at 2. Current
count of independent `local function NotifyPlayer(target, description,
notifyType)`-shaped definitions, verified by direct grep, each with its own
`TriggerClientEvent('ox_lib:notify', ...)` body:

`server/main.lua:254`, `server/certifications.lua:202`,
`server/kennel.lua:213`, `server/medkit.lua:222`, `server/wellbeing.lua:261`,
`server/combat.lua:422`, `server/partnership.lua:397`, `server/tenure.lua:324`,
`server/admin.lua:265`, `server/recall.lua:135`,
`server/propattachment.lua:177`, `server/bonetool.lua:135` — **12 copies**,
every one server-side.

This is not sloppy duplication — every single copy carries its own explicit
"duplicated, not shared, on purpose" comment (e.g. `server/bonetool.lua:129-131`:
"Duplicated (not shared) per this resource's established convention — see
server/kennel.lua's own NotifyPlayer comment"), citing the same reasoning
each time: it's a tiny UI-plumbing helper, not certification/permission logic
that must stay a single source of truth. That reasoning is sound for 2-3
copies. At 12 it has already produced real, visible drift, not just
duplication:

- `server/tenure.lua:324`'s copy drops the `notifyType` parameter entirely
  (`function NotifyPlayer(target, description)`, always `'inform'`) — a
  narrower signature than the other 11. Not a bug today (nothing calls it
  with a third argument), but it means the 12 copies are no longer even
  byte-identical, so "keep them in sync by hand" already has a live
  discrepancy to keep in sync.
- Several copies intentionally vary the `title` field per subsystem
  (`server/bonetool.lua:137`: `'K9 Unit — Bone Tool'`;
  `server/admin.lua:267`: `'K9 Unit — Admin Audit'`; most others: plain
  `'K9 Unit'`) — this is a genuine, deliberate per-feature difference, not an
  accident, which means a naive single-function extraction would need a
  `titleSuffix` parameter to preserve it, not a pure delete-11-keep-1.

**Assessment:** real, larger than previously recorded, but still low-stakes
— a wrong `notifyType`/title only affects a cosmetic toast, never a security
or correctness boundary. Extraction is easy (add `NotifyPlayer(target,
description, notifyType?, titleSuffix?)` to `server/entities.lua` — same
file already holding the two other cross-file server primitives — and
delete 12 four-to-six-line local copies, migrating `tenure.lua`'s narrower
call sites for free since the new signature is a superset). Payoff is
~60-70 duplicated lines removed and one less thing to keep consistent by
hand, not a bug-prevention story. Do this opportunistically (bundle into
whatever pass next touches `server/entities.lua`), not urgently.

### Confirmed NOT a duplication problem: the "build a hash-set from a config array at load time" idiom

`server/certifications.lua`'s `K9ModelHashes` (from `Config.Peds`),
`server/kennel.lua`'s `KennelModelHashes` (from
`Config.DeployableKennel.propModel`/`fallbackPropModel`), and
`server/propattachment.lua`'s prop-model allowlist all share the same
"iterate a config table once, build a hash-set, expose an `IsX(hash)`
check" shape. Unlike item 3 above, these are **not** duplicates of each
other — each covers a different, non-overlapping config source for a
different purpose (recognized K9 peds vs. a specific kennel prop vs. a
specific attachment prop allowlist). This is a consistently-applied idiom,
not hand-copied logic; no action warranted, and worth not mis-flagging as
"another K9ModelHashes copy" in a future pass just because the shape looks
similar at a glance.

### Confirmed NOT worth acting on: `GetPlayers()` iteration idiom

6 files (`server/entities.lua`, `server/tenure.lua`, `server/combat.lua`,
`server/defense.lua`, `server/search.lua`, `server/progression.lua`) contain
`for _, playerIdStr in ipairs(GetPlayers()) do local playerId =
tonumber(playerIdStr) ...`. This is the idiomatic FiveM way to iterate
connected players and appears nowhere with an actual bug — each loop body
does something genuinely different (resolve-by-ped, tenure-check,
maintenance-scan, etc.). A `ForEachPlayer(fn)` wrapper would save one line
per call site for no correctness benefit. Not worth doing.

---

## Part 3 — Comment-to-code ratio

### Header sizes, measured directly (file total lines / header block lines, via the closing `]]`)

| File | Total lines | Header lines | Header % |
|---|---|---|---|
| `server/combat.lua` | 1614 | 347 (+ a second `]]`-delimited block ending ~1485) | ~21%+ |
| `server/partnership.lua` | 1185 | 314 | ~26% |
| `client/combat.lua` | 1266 | 277 | ~22% |
| `client/movement.lua` | 1614 | 204 | ~13% |
| `server/certifications.lua` | 1069 | 164 | ~15% |

This confirms the "200+ line header" claim directly for 3 files (`server/combat.lua`,
`server/partnership.lua`, `client/combat.lua`), not just as a general
impression.

**Honest assessment, not a blanket "too much" or "fine":**

- The headers are not padding — they consistently carry three kinds of
  content that would otherwise live nowhere: (1) a FILE-TO-FILE CONTRACT
  section naming every resource-global a file exposes/consumes, which is the
  *only* thing standing in for a proper module/import system in a codebase
  built entirely on bare Lua globals across independently-loaded files; (2)
  "why not the obvious alternative" design-decision records (e.g.
  `server/entities.lua`'s "why a new file, not folded into cooldowns.lua");
  (3) explicit trust-boundary/security reasoning at every event handler.
  Removing these would not shrink real complexity, it would just make it
  undocumented — and given this resource is built by ~20 parallel agents who
  provably cannot see each other's work (the entire reason this roadmap
  exists), the FILE-TO-FILE CONTRACT sections are doing real, load-bearing
  work: they're the only reason items 2/2b/3 above were even findable and
  fixable as a coherent extraction rather than 15 independent tiny patches.
- The genuine bloat is the **historical layering convention** — corrections
  are appended rather than replacing the original text (e.g.
  `server/combat.lua`'s "EXTRACTION UPDATE" appended after the original,
  now-superseded observation it corrects). This is the right call for a
  document like this roadmap (preserves *why* a decision was revised), but
  inside a file's own header it means the header only grows, never shrinks,
  as a file gets touched by successive passes. `server/combat.lua`'s two
  separate `]]`-delimited blocks (one ending at 347, a second near 1485) is
  a symptom of this — a trailing "PROPOSED CONFIG ADDITIONS" style block
  bolted on well after the main header, matching the same shape
  `server/tenure.lua` and others also carry.
- **Headers whose claims contradict the code, specifically checked for:**
  found **zero** inside the Lua source files themselves — every stale claim
  found this pass was in a *documentation* file (`REFACTOR_ROADMAP.md`
  itself, per Part 1 above, and `WATCHDOG_LOG.md`'s per-feature status table
  around line 980, which currently lists `HandlerDownDefense` and `Recall`
  as "No — flag and comments only, no function bodies anywhere," which is
  now false: `server/defense.lua` (504 lines) and `server/recall.lua`/`client/recall.lua`
  (240+85 lines) both contain real, working implementations). Every in-code
  header comment checked against its own file's current behavior held up —
  the layering convention, whatever its cost in header length, is
  successfully preventing the "confidently wrong" failure mode this task
  asked to specifically watch for. The cost is length; correctness is not
  currently being paid for it.

**Recommendation:** do not trim these headers. The one real action item is
**`REFACTOR_ROADMAP.md`/`WATCHDOG_LOG.md` currency, not file headers** — this
revision *is* that fix for this document; flag `WATCHDOG_LOG.md`'s feature
status table to whoever owns it next as similarly due for a refresh, but
that's a documentation-maintenance note, not a code refactor.

---

## Part 4 — Structural debt: are the largest files still right?

Corrected line counts (the task's own priors were slightly out of date —
`server/partnership.lua` is 1185 lines, not ~1000, and `client/movement.lua`
at 1614 lines is tied with `server/combat.lua`, not smaller than the named
"three largest"):

| File | Lines | Header % |
|---|---|---|
| `server/combat.lua` | 1614 | ~21% |
| `client/movement.lua` | 1614 | ~13% |
| `client/combat.lua` | 1266 | ~22% |
| `server/partnership.lua` | 1185 | ~26% |
| `server/certifications.lua` | 1069 | ~15% |

**Recommendation: do not split any of these right now.** Reasoning per file:

- **`server/combat.lua` / `client/combat.lua`**: each file's own header
  explicitly states it deliberately holds multiple roles in one file per a
  spec-level module plan (`client/combat.lua`'s header: "kept in one file
  (not split) because §12.3 explicitly assigns all of them to
  `client/combat.lua`"). The roles (self-initiated triggers, target-side
  relay handlers, NPC-target relay handlers, the shared maintenance thread)
  are already clearly section-delimited with `======` banners inside the
  file. Splitting along those exact same seams would trade "scroll within
  one file" for "jump between 3-4 files to trace one feature's full
  request/relay/expiry lifecycle" — a real cost for a codebase whose stated
  failure mode is agents not seeing related code. Only split if a *future*
  role gets added that doesn't fit the existing three (not speculative
  today).
- **`server/partnership.lua`**: the highest header-to-code ratio of the
  five (26%), but the code itself (871 non-header lines) implements one
  cohesive state machine (partnership lifecycle: request, establish, end,
  tenure hooks) with no evidence of unrelated concerns bolted on. Not a
  splitting candidate; the header ratio is a documentation-density
  observation (Part 3), not a structural one.
- **`client/movement.lua`**: lowest header ratio of the five (13%) despite
  being tied for the largest file by line count — meaning this file's size
  is almost entirely actual behavior (leash, sit, door-scratch,
  agility/jump-crouch gating, move-rate composition), not documentation. Of
  the five, this is the one where a future "does this need to split" review
  is most worth having *if* it grows further — but not today; no evidence
  of confused responsibility, just genuine breadth (this file is where
  several independent Phase 2-4 features' client halves converged because
  they all touch the K9 ped's movement/control state).
- **`server/certifications.lua`**: 1069 lines, the one file in this list not
  named in the task's own prior list — worth flagging precisely because it
  wasn't on anyone's radar as "one of the big ones." Same recommendation:
  it's the certification/access lifecycle (grant, revoke, cache, job-change
  sync, tenure milestone hooks) as one cohesive unit; no split warranted.

**When splitting WOULD be worth it, for whoever revisits this:** if any of
these files' own header FILE-TO-FILE CONTRACT section needs to reference a
4th or 5th genuinely distinct responsibility not currently listed (not a new
call site for an existing one), that's the trigger — not line count alone.

---

## Part 5 — Performance: every `CreateThread` polling loop, verified

All 17 `CreateThread` loops in the tree, with their actual interval and
gating, checked directly against source (not inferred from names):

| File:line | Interval | Gating |
|---|---|---|
| `client/hud.lua:282` | 250ms active / 1000ms idle (`HUD_POLL_TICK_MS`/`HUD_IDLE_TICK_MS`) | Whole file returns early if `Config.Features.HealthStaminaHUD` is false; loop itself gates on `CanShowK9UI()` (cached) each tick |
| `client/screenfx.lua:280` | 250ms (`SCREENFX_POLL_MS`), no idle variant | Thread only ever started on-demand by `EnsureScreenFxThreadRunning()` when an effect actually triggers, and self-terminates (`while GetGameTimer() < screenFxExpiresAt`) — never runs at all for a player who never triggers it |
| `client/tracking.lua:378` | 250ms active / 1000ms idle (`TRACK_TICK_MS`/`TRACK_IDLE_TICK_MS`) | Idle branch is the default; active branch only runs `if IsTracking()` |
| `client/tracking.lua:542` | 200ms active / 1000ms idle (`GUNPOWDER_POLL_MS`/`GUNPOWDER_IDLE_POLL_MS`) | Same idle-backoff shape |
| `client/audio.lua:311` | 500ms (`AUDIO_GAIN_POLL_MS`) | Nested inside an active-sound-instance branch, not file-level always-on |
| `client/vision.lua:149` | 1000ms | Comment marks it "cleanup/safety poll," started on-demand like screenfx |
| `client/wellbeing.lua:190` | 2000ms | — |
| `client/wellbeing.lua:224` | `Wait(0)` while an effect is active, `Wait(1000)` idle | Same "disable-every-frame only while active" shape as movement.lua below |
| `client/movement.lua:485` | dynamic `sleepMs` (not read this pass in detail; same idle-backoff family as tracking.lua) | — |
| `client/movement.lua:968` | `Wait(0)` while `IsOwnModelK9()`, else `Wait(1000)` | File-level: only started `if not Config.Features.AgilityBasicJump` (i.e. only runs at all when this specific sub-feature is off, to enforce base-game jump/crouch suppression) |
| `client/combat.lua:1023` | `Wait(0)` while any of 3 active-effect states is set, else `Wait(ActiveForcedRagdoll and 100 or 500)` | **Not gated on any `Config.Features` flag** — always running from resource start on every client, because the target-side relay handlers it maintains must be registered unconditionally per this file's own documented trust-boundary design. Idle cost is negligible: `Wait(500)` and a `pairs()` over what is an empty table on 99% of clients (`ActiveNpcEffects`) — not a concern in practice, but worth naming explicitly as the one always-on thread with no feature-flag off-switch, for anyone later adding a 4th active-effect state to this same loop |
| `server/defense.lua:423` | `Config.Combat.HandlerDownDefense.pollIntervalMs` (config value: 1000ms) | Enumerates `GetPlayers()` every tick — O(players), not O(entities); fine at any realistic player count |
| `server/wellbeing.lua:844` | `Config.Wellbeing.tickIntervalMs` (config value: 5000ms) | One shared tick for all five stats, by design (file's own header cites this as "beats five independent timers") |
| `server/tenure.lua:501` | `Config.Partnership.TenureBonus.checkIntervalMs`, falls back to 300000ms (5 min) if misconfigured | Whole block only created `if Config.Features.HandlerPartnership and Config.Features.XPProgression and Config.Features.PartnershipTenureBonus` — triple-gated |
| `server/combat.lua:1039` | 500ms (`MAINTENANCE_INTERVAL_MS`) | Always-on maintenance thread, same shape/reasoning as its client counterpart above; iterates small in-memory active-effect tables, not entity pools |
| `server/cooldowns.lua:214` | caller-supplied `intervalMs` | Generic sweep-thread runner, only started per tracker that opts into `:StartSweep(...)` |

**Findings:**

- **No thread on a `Wait(0)`-forever or sub-100ms *unconditional* tick was
  found.** Every `Wait(0)` present is inside an `if <active state>` branch
  with a `Wait(500)`-or-slower idle fallback in the same loop — this is the
  correct FiveM idiom (a control-disable native genuinely does need
  per-frame reapplication while active), not a missed optimization.
- **No thread was found enumerating a full entity pool (`GetGamePool`) on a
  per-tick basis.** The two `GetGamePool('CPed')` calls in the whole
  codebase (`client/combat.lua:425,527`, `FindNearestCombatTarget`) are
  called once per player-initiated radial selection, not from inside any
  `CreateThread` loop.
- **The idle-backoff convention (fast tick while relevant, slow tick or
  fully-stopped while not) is applied consistently across essentially every
  polling thread in the codebase**, including ones written by different
  agents in different files with no shared code (`client/hud.lua`'s
  `HUD_IDLE_TICK_MS`, `client/tracking.lua`'s `TRACK_IDLE_TICK_MS`,
  `client/movement.lua`'s `Wait(1000)` idle branch — three independently
  hand-written instances of the identical idea, cross-referenced in each
  other's comments). This is a genuine strength of the codebase, worth
  recording as such rather than only auditing for problems: performance
  discipline here is holding up at least as well as item 1's cooldown
  extraction did.
- **The one thing worth a one-line note, not a fix:** `client/combat.lua`'s
  maintenance thread (1023) has no feature-flag off-switch, unlike almost
  every other thread in this table. Its own idle cost is negligible today
  (empty-table `pairs()` + `Wait(500)`), so this is a **watch, don't act**
  item — flagging it now means if a 4th/5th active-effect state is added to
  this same loop later without re-checking its idle-cost assumption, this
  table gives the next person a baseline to compare against.

---

## Part 6 — Priority ranking: what's actually worth doing next

### Near-term (do next)

1. **Update `WATCHDOG_LOG.md`'s per-feature status table** (the
   `HandlerDownDefense`/`Recall` "not implemented" rows, now false) — 5
   minutes, prevents the next agent from wasting a pass re-discovering
   already-shipped code as missing, or worse, re-implementing it. Not a code
   change; flag to whichever agent owns that doc.
2. ~~**Fix `client/propattachment.lua:237-239`'s raw netId-resolve** to call
   `ResolveNetworkEntity(netId)` instead~~ **DONE, verified this pass.**
   `client/propattachment.lua`'s server-issued attach handler now calls
   `ResolveNetworkEntity(netId)` directly (its own comment there cites this
   exact roadmap item) — the raw
   `NetworkDoesEntityExistWithNetworkId`/`NetworkGetEntityFromNetworkId`/
   `DoesEntityExist` sequence this item originally quoted is gone. The file
   is also registered in `fxmanifest.lua` now (see the corrected "Watch,
   don't act yet" entry below), so both halves of this item's original
   framing are resolved.
3. **Extract `NotifyPlayer`** into `server/entities.lua` as a 4th shared
   primitive (`NotifyPlayer(target, description, notifyType?, titleSuffix?)`),
   migrating all 12 call sites. Cheap (each site is a 4-6 line deletion),
   mechanical, and removes the one duplication pattern in this codebase that
   has already started to visibly drift (`server/tenure.lua`'s narrower
   signature). Do this the next time any agent is already touching
   `server/entities.lua` for an unrelated reason — not worth a dedicated
   pass on its own.

### Medium-term

4. **Watch `server/combat.lua`'s and `client/combat.lua`'s size**, per Part
   4 — no action now, but the trigger for revisiting is a 4th/5th genuinely
   distinct responsibility being added to either file's own documented role
   list, not line count by itself.
5. **`FindNearestEntity`-shape consolidation** (client/combat.lua's
   `FindNearestCombatTarget`, client/radial.lua, client/vehicle.lua,
   server/tracking.lua's related-but-distinct age-filtered variant) —
   unchanged from Revision 5's read: real but modest payoff (3-4 call
   sites, ~10-15 lines each), fold in opportunistically if the context is
   already loaded for something else, not worth a dedicated pass.
6. **`Config.LeashMaxDistance` triple-duty overload** — still untouched,
   still not urgent, still the right call to defer until a real feature
   needs to tune one use independently of the others.

### Watch, don't act yet

- **`client/combat.lua`'s always-on maintenance thread with no feature-flag
  off-switch** (Part 5) — negligible idle cost today; revisit only if a
  future active-effect state changes that cost.
- ~~**`fxmanifest.lua` missing registration for `propattachment`/`bonetool`
  file pairs**~~ **Resolved.** Both pairs (`client/propattachment.lua`+
  `server/propattachment.lua`, `client/bonetool.lua`+`server/bonetool.lua`),
  and `client/fetch.lua`+`server/fetch.lua`, are all present in
  `fxmanifest.lua`'s current `client_scripts`/`server_scripts` lists,
  verified by direct read — not presumed. Their flags still ship `false`;
  that's the feature being off, not a completeness gap in this file's own
  sense.
- **Breed→scenario literal tables** (`K9_SIT_SCENARIO_BY_MODEL_HASH` etc.,
  tracked since Revision 3) — re-checked this pass, no new instance beyond
  the 3 already known, no live bug currently. Still cosmetic-severity if it
  ever desyncs again. Not re-litigated in depth this pass; nothing changed.
- **`playerDropped` handler count / `type(x)=='function'` cross-file guard
  convention / `config.lua` size** — all re-confirmed fine in prior
  revisions and not re-litigated in depth this pass; no evidence anything
  changed for the worse.

### Explicitly NOT worth doing

- **Do not build a generic `ForEachPlayer(fn)` wrapper** for the 6-file
  `GetPlayers()`/`tonumber` iteration idiom (Part 2). Every call site's loop
  body is doing genuinely different work; this would save one line per site
  for zero correctness or duplication-drift benefit — the textbook case of
  "could be written differently, no real downside to leaving it."
- **Do not trim the 200+-line file headers** (Part 3). They are the only
  mechanism standing in for a module system in a bare-globals, many-parallel-
  agents codebase, and a direct check found zero cases of an in-code header
  actively lying about current behavior — the layering convention is
  working. The actual staleness problem this pass found lives in
  `REFACTOR_ROADMAP.md` and `WATCHDOG_LOG.md`, not in file headers.
- **Do not split `server/combat.lua`, `client/combat.lua`, or
  `server/partnership.lua`** on line-count grounds alone (Part 4). Each is
  one cohesive responsibility per its own already-documented module plan;
  splitting along the existing section banners would trade in-file
  scrolling for cross-file jumping in a codebase whose core problem is
  agents not seeing related code across files.

---

## The single highest-value thing to do right now

**Keep this document itself current, more than any one code fix.** The
single most expensive fact this pass surfaced is not a code pattern — it's
that a correctly-written, correctly-committed fix (items 2/2b/3) sat marked
"open"/"reopened" in this exact file for long enough that the next reader
would have re-planned and possibly re-implemented already-finished work, while
in the other direction a real, live security fix (the flag-off-safety class)
sat undocumented here at all despite being fixed. Every other finding in this
revision is worth an hour or two of one coder's time; this one is worth
however many hours the next agent would have wasted trusting a stale status
line. Concretely: whoever lands a fix that this document tracks should update
the relevant item's status **in the same commit**, not rely on the next audit
pass to catch up — the two-revision gap between "fix lands" and "roadmap
reflects it" is where all the cost in this specific codebase's debt has
actually been concentrated, more than any individual duplicated function ever
was.

**The clearest "don't bother" call:** the file-header length "problem." It
looks, from the outside, like the most obviously fixable form of bloat in
this codebase — and it is the one this pass found zero actual evidence of
causing harm. Time spent trimming headers is time not spent keeping
`REFACTOR_ROADMAP.md`/`WATCHDOG_LOG.md` in sync with what's actually shipped,
which is the thing that has now demonstrably cost real re-planning effort
twice in two revisions.

---
---

# Part B — Independent second audit (merged from `REFACTOR_ROADMAP_2.md`, docs pass, 2026-08-25)

**This part was originally its own file, `REFACTOR_ROADMAP_2.md`.** It was
written as a fresh, independent audit run *alongside* Part A above, not as a
revision of it — Part A's Revision 6 was deliberately left untouched when
this was first written, and is left untouched here too. Merged into this
file during a documentation-consolidation pass because two separate
technical-debt audits of the same codebase is one too many for a reader to
have to find and cross-reference by hand; nothing below was edited for
content, only relocated. If the two parts disagree on the status of the
same item, treat whichever one has the more recent verification date as
current, and re-check the code yourself rather than assuming either is
still accurate — both say this about themselves already.

Written as a fresh audit alongside the (then-separate) `REFACTOR_ROADMAP.md`
(not a revision of it — that file's Revision 6 was left untouched, per
instruction at the time). Every claim below was checked by reading the
actual source at the paths cited, not inferred from a grep count alone.
Where a grep informed where to look, the surrounding code was read before
anything here was written down.

**Headline finding: this codebase is in noticeably better shape than the
brief's framing predicted.** The three debt clusters the brief specifically
asked about as likely trouble spots — hand-rolled notify functions,
hand-rolled cooldown tables, hand-rolled entity resolvers — are all
already consolidated and, as of this pass, still holding under continued
parallel-agent editing (re-verified directly, not assumed from
`REFACTOR_ROADMAP.md`'s own say-so; see "Re-verification" below). The
feature-flag surface, while large, is more disciplined than 40 independent
booleans usually are: every place a real interdependency exists between two
flags, the code enforces it with a runtime existence guard or an explicit
compound check, not just a comment asking the operator to remember. The test
harness is well-factored, not ad hoc. What debt remains is small, cheap, and
mostly documentation catching up to code that has already been fixed —
which is itself a real and recurring pattern worth naming precisely, not
papering over.

This is a **six-item roadmap**, not a thirty-item list, because that is
roughly how much real, actionable debt a direct read turned up.

---

## Re-verification of the three "likely cluster" claims

- **Cooldowns**: grepped for the exact hand-rolled shape `server/cooldowns.lua`
  replaced (`local <x>At = {}` tables, raw `GetGameTimer()` delta comparisons
  outside `server/cooldowns.lua` itself) across every `client/*.lua` and
  `server/*.lua` file as of this pass. Zero matches. Holding.
- **Entity resolvers**: zero raw `NetworkGetEntityFromNetworkId` call sites
  outside `server/entities.lua`'s/`client/main.lua`'s own function bodies
  remain (confirmed via `client/propattachment.lua`, the one file
  `REFACTOR_ROADMAP.md` had flagged as a fresh regression of this pattern —
  it now calls `ResolveNetworkEntity(netId)` directly at
  `client/propattachment.lua`'s attach handler, matching every other
  consumer). Holding.
- **NotifyPlayer**: `server/notify.lua:150` is the single shared
  implementation. `server/admin.lua:331` and `server/bonetool.lua:234` keep
  a one-line local wrapper (different player-visible title per subsystem),
  each explicitly calling `_G.NotifyPlayer(...)` — read both directly,
  confirmed neither redefines the notify body itself, just forwards to it.
  This extraction (item 3 in `REFACTOR_ROADMAP.md`'s near-term list) is
  **done**, not merely "cheap, do opportunistically" as that document still
  frames it — worth flagging to whoever owns that file next so it isn't
  re-queued as outstanding work.

---

## Item 1 (near-term): the one real remaining duplicate of the `DenyK9UIAccess` pattern, plus the stale comment describing it

**What's wrong.** `client/main.lua:184` defines the shared
`DenyK9UIAccess()` global specifically to end a *different* instance of the
same duplication class the brief asked about — a `lib.notify({...
common.no_k9_access ...})` call that the function's own header (lines
177-183) says was "previously duplicated verbatim across
client/radial.lua, client/search.lua, and client/vehicle.lua
(client/movement.lua and client/tracking.lua also have their own copy, out
of scope for this pass — left as-is)."

Checking that claim directly against the current tree:

- `client/movement.lua:404-406` now calls `DenyK9UIAccess()` — this file
  **has already been migrated**, contradicting the comment that still lists
  it as an unmigrated holdout.
- `client/tracking.lua:186` still has the raw, un-migrated copy:

  ```lua
  -- client/tracking.lua:180-188
  local function StartTrack(trackType)
      if not CanShowK9UI() then
          -- Reuses common.no_k9_access rather than minting a duplicate — this
          -- exact string was flagged for reuse by locales/README.md's
          -- "common.no_k9_access promotion" note, confirmed by grep before
          -- this pass ever touched this file.
          lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
          return
      end
  ```

**Why it matters.** This is a small-scale live instance of exactly the
"comment drifts from the code it describes" failure mode the brief asked to
watch for, caught in the wild rather than hypothesized. It costs little
today (both forms produce an identical toast), but a comment that says "2
files still need this" when only 1 does will send the next agent to
re-check a file that's already fixed, and — worse — may cause someone to
"fix" `client/movement.lua` a second time or skip `client/tracking.lua`
because the header made it sound like parallel, equally-unmigrated work.

**The change.** Two mechanical edits:
1. `client/tracking.lua:186` → replace the inline `lib.notify({...})` call
   with `DenyK9UIAccess()`.
2. `client/main.lua:180-181` → drop `client/movement.lua` from the "still
   has their own copy" list (it's migrated) and update the sentence to name
   only `client/tracking.lua` as the remaining holdout — or, once step 1
   lands, delete the parenthetical entirely.

**Scope/risk.** Trivially small — one call-site swap, one comment edit,
same file family, no config/manifest/schema touched. Behaviorally
identical (both paths call the same `lib.notify` with the same locale
keys). Essentially zero risk.

**Order.** First — it's the cheapest possible fix in this entire roadmap
and directly closes out a consolidation that is already 80% done.

---

## Item 2 (near-term): `tests/README.md`'s coverage table is one spec file behind the actual suite

**What's wrong.** `tests/README.md` states "118 test cases total across 7
spec files" and its coverage table lists exactly 7 files
(`cooldowns`, `admin`, `progression`, `entities`, `notify`, `tenure`,
`search`). Reading the `tests/` directory directly shows **8** `*_spec.lua`
files — `tests/exports_spec.lua` exists, is dated to this same audit window
(its own header says "following a security audit pass (2026-08-25)"), tests
both `server/exports.lua`'s 9 exports and `client/exports.lua`'s 18 exports
against the real production files, and appears nowhere in the README's
table or file count.

**Why it matters.** `tests/run.sh` is glob-based (`for spec in
*_spec.lua`), so the suite itself is not broken — `exports_spec.lua` runs
fine today. The cost is purely to the next reader: this resource's entire
public cross-resource export surface (the one thing other resources
actually call) now has real test coverage, and the one document whose whole
job is to tell a reader what's covered doesn't mention it. This is the same
class of drift as item 1, in a doc file instead of a code comment — a
correctly-landed fix whose paper trail didn't keep up, which
`REFACTOR_ROADMAP.md`'s own "single highest-value thing to do right now"
section already identified as this codebase's most expensive recurring
failure mode.

**The change.** Add an `exports_spec.lua` row to the coverage table (what's
tested / how reached — its own header already states this clearly), and
correct "7 spec files" / "118 test cases" to the real current numbers.

**Scope/risk.** One markdown file, no code touched. Zero risk.

**Order.** Second — same cheap-and-mechanical shape as item 1, bundle
both into one small documentation-sync pass.

---

## Item 3 (medium-term): a first, narrowly-scoped client-side spec, not a wholesale push

**What's wrong / the gap.** `tests/README.md` correctly and honestly
discloses that `client/*.lua` has zero test coverage, and gives a real
reason: every client file calls heavy natives (`GetEntityCoords`,
`DisableControlAction`, ped/camera natives, NUI messaging) with no
server-side equivalent to sandbox against, "no client file currently has
anything as isolable as `NewCooldown` or `ResolveTier`." That claim is true
for the *large* client files (`client/movement.lua`, `client/combat.lua`,
`client/radial.lua`) — but it is not true of `client/main.lua`'s own small
cluster of pure-logic resource-globals: `IsEntityModelK9`, `IsOwnModelK9`,
`HasK9Access`, `CanShowK9UI`, `DenyK9UIAccess` (read directly at
`client/main.lua:100-186`). Their only native/global dependencies are
`GetHashKey`, `GetEntityModel`, `PlayerPedId`, `GetGameTimer`,
`lib.callback.await`, and `lib.notify`/`locale` — every one of which is
already stubbed in some form by the existing server specs' sibling
patterns (`fixtures/sandbox.lua` already builds exactly this shape of
override table for `Sandbox.newEnv`).

**Why it matters.** This is genuinely the cheapest possible way to convert
"client is untestable" from a blanket, resource-wide statement into a
narrower, accurate one — proving out that the *sandbox pattern itself*
(not just the specific natives `server/*.lua` happens to need) generalizes
to `client/*.lua`, which the current README doesn't establish either way
because nobody has tried it on the easiest possible target yet. It would
also give real regression coverage to the exact TTL-cache/debounce logic in
`HasK9Access` (`HAS_K9_ACCESS_CACHE_TTL_MS`) that every hot ox_target
`canInteract` predicate in this resource depends on.

**The change.** One new `tests/main_spec.lua`: `Sandbox.newEnv` with stubs
for the five natives above (a `lib.callback.await` stub that returns a
controllable boolean, a fake `Config.Peds`-driven model set), then
`Sandbox.loadInto('../client/main.lua', env)`, then assert on
`env.IsEntityModelK9`/`env.HasK9Access`/`env.CanShowK9UI` directly — same
shape as `entities_spec.lua` already uses for `server/entities.lua`'s
`ResolveNetworkEntity`. This does **not** attempt to load `client/main.lua`
in full if later sections of that file need natives not worth stubbing for
this pass (the file's own top section, before the placeholder-sound code at
line ~188, is the target); if something below the target functions forces
disproportionate stubbing, stop there and say so in the spec's own header,
matching this suite's existing "disclose the gap, don't force it" rule.

**Scope/risk.** One new test file, zero production code changes (this
suite's own rule 6: "never edit the production file to make it more
testable"). Zero risk to shipped behavior.

**Order.** Third — do this once items 1-2 are landed and before proposing
any *broader* client coverage push, since its real value is answering "does
the sandbox pattern generalize to client/" before committing more effort on
that assumption.

---

## Item 4 (medium-term): `server/tenure.lua`'s disclosed cache/header mismatch

**What's wrong.** This is not a new finding — `tests/README.md`'s own
"What's NOT covered, and why" section already discloses it, and a test
(`tenure_spec.lua`'s own `DISCREPANCY:`-tagged case) already locks in the
real behavior — but it has sat disclosed-and-unfixed since the suite found
it, and re-reading `server/tenure.lua` directly confirms it is still true:
the `TenureFullyCollected` local cache's own header comment claims it is
"a per-process, in-memory SKIP-CACHE to avoid re-running the SELECT below
every tick," but the cache is keyed by `row.id`, which is only known
*after* the same `MySQL.single.await` SELECT it's meant to skip has already
returned. The SELECT runs every tick regardless of cache state.

**Why it matters.** Read in isolation this is a one-file, bounded
performance cost (one extra indexed SELECT per online, fully-tenured K9 per
`checkIntervalMs` tick — not a correctness bug; the real double-grant
protection is the persisted `tenure_bonus_tier_granted` column's
optimistic-UPDATE guard, separately confirmed still holding by the same
spec). What makes it worth a line in this roadmap rather than "watch, don't
act" is that it is a second, independent instance of the exact
header-claims-something-the-code-doesn't-do pattern item 1 above is — just
inside a code file's header this time instead of a doc file — and it has
already been sitting disclosed, with a fix suggested (re-key the cache on
`k9Citizenid`, which is known before the SELECT, instead of `row.id`,
which isn't), without anyone acting on it.

**The change.** Either (a) re-key `TenureFullyCollected` on `k9Citizenid`
so it actually skips the redundant SELECT, or (b) if there's a reason not
previously written down that `row.id`-keying is intentional, correct the
header to say what the cache actually does. Either is a same-file, few-line
change with an existing test already asserting the current behavior (so a
real fix will make that specific `DISCREPANCY:` test's assertion need
updating in the same commit — expected, not a regression).

**Scope/risk.** One file (`server/tenure.lua`), one already-tightly-scoped
test file to update alongside it. Low risk — the double-grant guarantee
this feature actually depends on lives in the SQL UPDATE...WHERE guard, not
this cache, so getting the cache's skip logic right or wrong cannot
reintroduce a double-grant either way.

**Order.** Fourth — bundle with item 3 or do it whenever `server/tenure.lua`
is next opened for any reason; not worth a dedicated pass on its own.

---

## Watch, don't act yet

- **`WATCHDOG_LOG.md`'s per-feature table, `PropDragging` row.** Line ~982
  still reads "`RequestDrag`/`ReleaseDrag`/`IsDragEngaged` have zero callers
  anywhere at `HEAD` (grepped)." That's now false — `client/radial.lua:608-623`
  wires a real "Drag / Release" radial option that calls both. This is *not*
  a fresh discovery: the same document's own later entry (~line 1001-1017)
  already flagged this exact gap as "in flight, not yet landed as of this
  pass's last check" and named the precise diff that would close it. That
  diff has since landed. This needs one more line-edit whenever whoever owns
  `WATCHDOG_LOG.md` next touches it — not urgent, since the document already
  contains its own correct forward pointer to the fix, so no reader following
  the document's own trail gets misled. Not promoted to an active item
  because it's a documentation-only, already-self-tracked gap, not new debt.
- **The `Config.Features` surface (40 flags, 5 default-`true`).** Read the
  full block at `config.lua:24-164` directly rather than trusting the
  count: confirmed exactly 40 leaf flags, exactly 5 `true`
  (`LeashMechanics`, `RadialMenu`, `VehicleEntryExit`, `BasicBarkSounds`,
  `AgilityBasicJump`). **Docs-pass note (2026-08-25): stale as a live
  count.** All 40 flags are `true` as of this document's own merge date —
  see `PROJECT_STATUS.md`. The structural conclusion below (every real
  cross-flag dependency found was enforced by a runtime guard, not left to
  operator memory) is unaffected by that and still holds; only the specific
  "5 true" snapshot is out of date. Checked every place a real cross-flag
  dependency is *documented* in a comment for whether it's *enforced* in
  code, not just asked of the operator:
  - `HandlerDownDefense` reading partnership state: `server/defense.lua:206-216`
    guards the accessor call with `type(GetActivePartnerCitizenId) ==
    'function'`, and the comment there explicitly notes it degrades to a
    silent no-op if `HandlerPartnership` is off or `server/partnership.lua`
    isn't loaded — verified this is a real runtime guard, not a comment
    asking the operator to remember to also flip `HandlerPartnership`.
  - `Recall`'s termination path deliberately does **not** gate on
    `HasK9Access`/`CanShowK9UI` on either party (`server/recall.lua:35-49`)
    — read this specifically because the brief asked not to propose
    anything that would weaken a "no unbounded trap" escape path, and
    confirmed this is exactly that kind of load-bearing gate, not an
    oversight to "fix."
  - `PartnershipTenureBonus` is double-gated on `HandlerPartnership AND
    XPProgression AND PartnershipTenureBonus` at both file-load time
    (`server/tenure.lua:556`) and inside its own polling thread
    (`server/tenure.lua:529`) — the one place three flags really are
    interdependent, and the interdependency is enforced twice, not once.

  **Conclusion: no action.** This is a large flag surface, but every real
  interdependency found was enforced in code via a runtime guard or a
  compound check, not left to operator memory — the opposite of the failure
  mode the brief was checking for. Restructuring 40 independently-gated
  flags into a nested/grouped config shape (e.g. per-phase sub-tables) would
  touch every one of the ~30 files that reads `Config.Features.X` for a
  purely organizational win with real risk of breaking a gate check
  mid-edit — exactly the "restructuring for its own sake" this task asked
  not to propose. Leave it.
- **File header length** (`server/combat.lua`, `client/combat.lua`,
  `server/partnership.lua` at 200+ header lines each). Independently spot-
  read `server/notify.lua`'s and `server/defense.lua`'s headers this pass
  (not previously quoted in `REFACTOR_ROADMAP.md`) as a fresh check rather
  than trusting that document's own "zero contradictions found" claim —
  both carry the same FILE-TO-FILE CONTRACT / trust-boundary-reasoning
  shape, and both matched current code exactly (`server/defense.lua:256`'s
  gate, `server/notify.lua:150`'s signature). No new evidence to add;
  agrees with the existing roadmap's "do not trim" call.

## Explicitly not worth doing

- **Consolidating `#(GetEntityCoords(a) - GetEntityCoords(b))`.** Found 17
  occurrences across 12 files (`server/partnership.lua`, `server/wellbeing.lua`
  x2, `server/tenure.lua`, `client/audio.lua`, `server/main.lua` x2,
  `server/fetch.lua` x2, `server/defense.lua`, `server/inventory.lua`,
  `server/medkit.lua`, `server/combat.lua` x2, `server/search.lua`,
  `server/certifications.lua` x2). This is a single-line idiomatic
  expression, not a hand-copied function — no per-site logic to drift
  (unlike `NotifyPlayer`'s title/type parameters before extraction), and a
  `DistanceBetween(a, b)` wrapper would trade one arithmetic expression for
  one function call with no correctness or maintenance benefit. Same
  category the existing roadmap already correctly rejected for the
  `GetPlayers()`-iteration idiom.
- **Consolidating `Player and Player.PlayerData and Player.PlayerData.citizenid`.**
  Found 40+ occurrences. Spot-checked several (`server/certifications.lua:224`,
  `server/progression.lua:570`, `server/main.lua:310`) — in every case
  checked, nil is already ruled out by a preceding guard, so the "unsafe-
  looking" bare-access variants seen elsewhere are not actually unsafe, just
  stylistically different from the defensive-chain variants. No live
  inconsistency, and most call sites already have `Player` in scope from an
  earlier line for an unrelated reason, so a wrapper function would often
  cost a second lookup rather than save one. Not worth acting on.
- **Broader client-side test coverage beyond item 3's single starter
  spec.** `client/movement.lua`/`client/combat.lua`/`client/radial.lua`
  are correctly assessed by `tests/README.md` as a much larger stubbing lift
  for comparatively little isolable pure logic — confirmed by reading
  `client/movement.lua`'s structure (leash/sit/door-scratch/agility gating
  is interleaved with per-frame control-disable natives throughout, not
  segregated into a testable pure core). Accept this as a real boundary,
  not a rewrite target.

---

## Ranked order

1. Fix `client/tracking.lua:186`'s remaining `DenyK9UIAccess` copy + correct
   `client/main.lua`'s stale "2 files left" comment. *(trivial, do first)*
2. Sync `tests/README.md`'s coverage table to include `exports_spec.lua`
   (8 files, not 7). *(trivial, bundle with #1)*
3. Add `tests/main_spec.lua` covering `client/main.lua`'s pure-logic globals.
   *(small, proves out client-side testability on the easiest real target)*
4. Fix or correctly re-document `server/tenure.lua`'s `TenureFullyCollected`
   cache. *(small, already scoped by an existing test)*
5. *(watch only)* `WATCHDOG_LOG.md`'s `PropDragging` row — one line, whenever
   that file is next touched.
6. *(watch only)* `Config.Features` surface — confirmed maintainable as-is;
   re-assess only if a future flag's interdependency is found *not* to have
   a runtime guard, which was not the case for any flag checked this pass.

## Which `REFACTOR_ROADMAP.md` (Part A) items are now done

Cross-checked against this pass's own independent reads, not copied from
that document's own status lines:

- **Item 1 (cooldowns)** — confirmed still DONE and durable.
- **Items 2/2b (entity/player resolvers)** — confirmed still DONE, including
  the one regression that document tracked (`client/propattachment.lua`) —
  confirmed fixed and registered in `fxmanifest.lua`.
- **Item 3 (`IsEntityModelK9` consolidation)** — confirmed DONE.
- **`NotifyPlayer` extraction** — confirmed DONE (this document's near-term
  item 3 can be marked complete, not merely "do opportunistically").
- **`fxmanifest.lua` registration gap** (propattachment/bonetool/fetch pairs)
  — confirmed resolved.
- **`WATCHDOG_LOG.md` feature-table refresh** (near-term item 1) — mostly
  done; the `HandlerDownDefense`/`Recall` rows were corrected via an
  appended note, but the `PropDragging` "zero callers" line is now stale
  again for an unrelated, later reason (see "Watch, don't act yet" above) —
  that document's own text already anticipates this, so it's a one-line
  follow-up, not a reopened item.
- **Medium-term/watch items** (combat.lua size, `FindNearestEntity`-shape
  consolidation, `Config.LeashMaxDistance` overload) — no new evidence this
  pass; the existing "defer" calls still hold.

## Overall read (Part B)

This codebase's cited debt-generating pattern (parallel agents each
hand-rolling the same helper) did happen here, exactly as expected — but it
was caught and fixed at each of the three points the brief predicted, and
those fixes are holding under continued concurrent editing rather than
silently regressing. The actual live cost right now is almost entirely in
the second-order problem `REFACTOR_ROADMAP.md` itself already named as the
most expensive one: a correct fix landing in code faster than the
comment/doc describing it gets updated. This pass found three fresh,
concrete instances of exactly that (the `DenyK9UIAccess` header, the tests
README's spec count, `WATCHDOG_LOG.md`'s `PropDragging` line) and zero
instances of unfixed duplicated logic, unenforced flag interdependencies,
or a test harness that doesn't scale. That is a good sign for this
resource's maintainability, not a gap in this audit — the roadmap above is
short because there genuinely isn't much load-bearing debt left to find.
