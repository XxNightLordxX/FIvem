# qbx_k9unit — Technical Debt / Refactor Roadmap

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
Trivial one-line fix once `client/propattachment.lua` settles down (replace
3 lines with `local entity = ResolveNetworkEntity(netId)`); not urgent by
itself (this file isn't even wired into `fxmanifest.lua` yet), but it should
not ship as-is, and it's worth a note to whoever is finishing
`client/propattachment.lua` before it does.

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
2. **Fix `client/propattachment.lua:237-239`'s raw netId-resolve** to call
   `ResolveNetworkEntity(netId)` instead — one line, in a file that's already
   being actively written this session, so the cheapest possible time to
   catch it is right now before it's "shipped" and needs a second pass to
   revisit. Low urgency only because the file isn't wired into
   `fxmanifest.lua` yet anyway.
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
- **`fxmanifest.lua` missing registration for `propattachment`/`bonetool`
  file pairs** — not a refactor item, a completeness gap in in-progress
  work; will presumably resolve itself as those files finish landing. Flag
  to project-lead if it's still missing once those files stop changing.
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
