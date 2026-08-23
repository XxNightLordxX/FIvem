# qbx_k9unit — Feature Ideation (post-Phase-1 / cross-phase)

Author: feature-ideation-agent
Date: 2026-08-23
Status: Ideation only — nothing below is speced or approved. Route to
product-manager for scoping before any code is written; route anything
touching money/items/progression to economy-balance-agent first per the
process this repo already follows for `Config.XPTiers`/
`Config.ContrabandAlertTiers`; route anything touching the
`k9_certifications` schema to db-schema, since that table's invariants
(§4.3 of SPEC.md) were reviewed once already and any change to its shape
should get the same scrutiny.

Grounded in a full read of `SPEC.md` (Phase 1 shipped, Phase 2 spec'd in
§11, Phases 3-5 scoped in §2/§8/§6) and the actual shipped Phase 1 code
(`config.lua`, `server/main.lua`, `server/certifications.lua`,
`client/radial.lua`, `README.md`). Every idea below is either (a) a gap
between what the existing design already implies/half-builds and what
code actually exists, or (b) a standard companion feature in comparable
FiveM K9 resources that this spec's five phases currently have zero
mention of.

---

## Tier A — small effort, clear value, buildable against Phase 1 as it
ships today (no dependency on unbuilt phases)

### 1. K9 handler roster / admin listing UI
**What:** A `/k9roster [job]` command (certifier-eligible only, same gate
as `/k9certify`) and/or an ox_target "K9 Handlers" option on a department
noticeboard/computer, listing every row from
`SELECT citizenid, granted_by, granted_at FROM k9_certifications WHERE job = ? AND active = 1`
— plus a one-click "Revoke" action per row for online targets, deep-linking
into the existing `RevokeCertification`/`RevokeCertificationOffline` path.

**Why now:** This is the single most concrete "we built the data model for
this but never shipped the feature" gap in the repo. §4.3 of SPEC.md
explicitly lists "a table trivially supports 'list all certified handlers
in department X' for an admin command/menu without scanning every player's
metadata JSON" as a stated *rationale* for choosing a dedicated table over
metadata — and `README.md`'s own Database section hands the exact query to
run. Nobody ever wrote the command/menu that runs it. Today, a chief who
wants to know who on their roster is currently K9-certified has no way to
find out in-game short of hand-running SQL. That's a real, daily
management friction point for anyone actually running a K9 unit with more
than 2-3 handlers.

**Effort:** Small. Pure read query (already documented) + a thin ox_lib
context menu or command formatter. Revoke wiring reuses
`RevokeCertification`/`RevokeCertificationOffline` verbatim — no new
authorization logic needed.

**Value:** High relative to effort. Directly closes a stated design intent.

**Dependency:** None. Buildable today.

---

### 2. Revoke reason code (extends the audit trail SPEC.md already justified)
**What:** An optional `reason` parameter on `/k9decertify [id] [reason?]`
and `/k9decertifyoffline`, stored as a new nullable `revoke_reason VARCHAR`
column (free text or a small fixed enum — retired / reassigned /
disciplinary / performance — whichever db-schema prefers) alongside the
existing `revoked_by`/`revoked_at`.

**Why now:** SPEC.md §4.3 justifies the dedicated table specifically
because "an audit trail... is a de facto requirement of any
permission-granting system with this size of blast radius" — but the
shipped audit trail only records *who* and *when*, never *why*. For a
system whose own design rationale leans on "audit trail," recording zero
reason for a revoke is a real gap, especially once Tier A #1's roster UI
exists and someone actually wants to *read* that history and understand a
past decertification, not just see that one happened. This is also the
closest thing this spec has to a "K9 retirement" flow the prompt asked
about — `revoked_by = 'retired'` (a deliberate, categorized manual revoke)
reads very differently in an audit log than an unexplained pull.

**Effort:** Small. One migration (`ALTER TABLE ... ADD COLUMN
revoke_reason ...`, nullable, no backfill needed since it's new), one
extra optional arg threaded through two existing command handlers and the
two existing `RevokeCertification`/`RevokeCertificationOffline` functions.

**Value:** Moderate-high, especially paired with #1.

**Dependency:** None structurally, but db-schema should confirm the
column shape (enum vs free text) since it touches the reviewed table.

---

### 3. Leash "Heel" / recall command for the handler side
**What:** A new radial/ox_target action, available only to the
handler-role party of an *active* leash pairing, that issues an immediate
"come here" command to the K9-role partner (server-relayed, then the K9's
own client runs a short `TaskGoToEntity`/walk-to toward the handler),
distinct from the existing passive elastic pull-back that only engages
once the K9 exceeds 75% of `Config.LeashMaxDistance`.

**Why now:** The leash subsystem already tracks exactly the state this
needs — `LeashPairs[src] = { partner, isK9 }` already distinguishes roles,
and `server/main.lua`'s leash consent handshake already has the pattern
for a small server-relayed action between two paired parties. Right now
the *only* thing the handler side of a leash pairing can actively do is
detach — there's no way to say "come here now" short of walking toward
the K9 themselves and waiting for the passive constraint to eventually
kick in. That's a real, obvious usability gap in a mechanic that's
otherwise fully built: the pairing/role infrastructure exists, but the
handler side got no actual command, only a passive physics effect.

**Effort:** Small. One new server event mirroring `detachLeash`'s shape
(look up `LeashPairs[source]`, confirm caller is the officer-role half,
relay to the partner), one client-side task call.

**Value:** Moderate — meaningfully rounds out a mechanic that's otherwise
already shipped and will get heavy use once Phase 2/3 tracking and
apprehension actions give handlers more reasons to want their K9 back
quickly.

**Dependency:** None. Builds directly on Phase 1's `LeashPairs`.

---

### 4. Give `Config.Peds`' breed data actual mechanical weight
**What:** Extend each `Config.Peds` entry with optional stat modifiers
(e.g. `scentBonus`, `speedBonus`, `biteBonus`) consumed once the relevant
Phase 2/3/4 mechanics exist (scent range, bite-and-hold effectiveness,
base move speed) — a Malinois configured with a scent bonus, a Rottweiler
with a bite bonus, etc.

**Why now:** `README.md` says outright: *"`label` is currently unused by
any code path (no UI reads it yet) but is kept for forward
compatibility."* The config already telegraphs that per-model
differentiation was anticipated and never delivered — right now every
recognized K9 model is mechanically identical, so breed choice is purely
cosmetic despite the spec's own roster design implying otherwise. This
also composes naturally with the XP tier multipliers already in
`Config.XPTiers` (`speedMultiplier`, `scentRange`) — the two systems
should stack, not conflict, so worth deciding the shape now rather than
retrofitting after Phase 4 ships XP tiers with their own multiplier
convention.

**Effort:** Small to *decide the config shape* now; the actual mechanical
payoff is deferred until Phase 2 (scent) / Phase 3 (bite) / Phase 4 (base
speed) land — so this is really "bake the hook into the config schema
during those phases' own design," not a standalone build.

**Value:** Moderate now (mostly a config-schema decision), higher later
(real reason to choose a breed beyond cosmetics).

**Dependency:** Payoff depends on Phase 2/3/4 landing; the schema decision
should happen before those phases lock in their own multiplier logic, to
avoid two divergent "how do modifiers stack" conventions.

---

## Tier B — medium effort, real value, time-sensitive (better decided
before Phase 3 hard-codes a binary certification model further)

### 5. Tiered certification (Trainee → Certified → Senior) instead of a
single active/inactive boolean
**What:** Add a `tier` (or `rank`) dimension to `k9_certifications`
alongside the existing `active` boolean — e.g. `trainee` gets
`LeashMechanics`/`RadialMenu`/basic locomotion only, `certified` unlocks
`SearchZones`/tracking, `senior` unlocks `BiteAndHold`/
`NonLethalTakedown`/`HandlerDownDefense`. A certifier grants an initial
tier and can later promote/demote it, using the exact same grant/revoke/
audit infrastructure already built — this is additive to the existing
schema and flow, not a redesign of it.

**Why now, specifically:** Every Phase 2/3 feature gate currently checks
one boolean (`HasK9Access`). Phase 3 in particular (bite-and-hold,
non-lethal takedown, handler-down defense — all mechanics with *real,
hard-to-undo consequences on other live players*) is about to get built
against that same single boolean. If tiering is wanted at all, it is
**much** cheaper to design in now, while only Phase 1's leash/radial/
vehicle checks exist, than to retrofit after Phase 2 and Phase 3's code
both already call `HasK9Access(source)` as a flat yes/no in a dozen
places. This is exactly the "certification retirement/reassignment"-
adjacent extension the task asked about: a tier demotion (senior →
trainee) is a natural, non-punitive way to handle "this handler needs a
refresher" without the blunt instrument of a full revoke.

**Effort:** Medium. Schema change (new column + migration, reviewed by
db-schema since it changes the table's invariants beyond what was already
signed off), and every future Phase 2/3 gate needs to check tier instead
of (or in addition to) the boolean — more a "decide the convention once"
cost than a large one, but it touches more surface than Tier A items.

**Value:** High as a long-term backbone — it's the natural foundation for
idea #6 below, and matches how real K9 units actually operate (trainees
don't go straight to apprehension duty).

**Dependency/urgency:** Should be decided *before* Phase 3 starts, not
after — this is the one idea on this list with a real "the window to do
this cheaply is closing" argument. Route to product-manager and
economy-balance-agent (progression-gating shape) together, soon.

---

### 6. Training-mode / practice sandbox, distinct from live duty
**What:** Admin-configured training zones (e.g. a K9 yard at each
department) where `SearchZones` (Phase 2) and `BiteAndHold`/
`NonLethalTakedown` (Phase 3) can be rehearsed against a scripted training
dummy/prop instead of a real player or real ox_inventory contents —
same UI/animation flow, but the server-side callback recognizes "this is
a training-zone trigger" and returns a scripted/fake result rather than
touching real inventory or applying real control-disable/ragdoll effects
to a live player.

**Why now:** This is exactly the gap the task explicitly flagged, and
it's a genuine one: Phase 2's search callback and Phase 3's bite-and-hold/
takedown are the *only* two mechanic families in this entire spec with
real, live consequences on another player or another player's real
inventory (§11.4 spends multiple paragraphs on why `searchTarget` must be
airtight server-side specifically because it reveals real contents) — and
there is currently no lower-stakes way for a newly certified handler to
learn the interaction flow before their first live use is also their
first-ever use. Every comparable real-world K9 program has a training
range before field certification; this spec has no equivalent at all
across all five phases.

**Effort:** Medium. Needs a `Config.TrainingZones` schema, a scripted
dummy ped/prop (not a "K9 spawn" — this is a *target* dummy, doesn't
touch the no-spawn-K9 rule), and a branch in `server/search.lua`'s (and
eventually Phase 3's) callback logic to detect a training-zone trigger and
short-circuit to a fake result before any real ox_inventory/ped-effect
code runs.

**Value:** High, especially once Phase 3 ships — reduces the real risk of
a rookie handler's first live bite-and-hold or search being their first
attempt at the mechanic at all.

**Dependency:** Pairs naturally with #5 (a `trainee` tier could be
*restricted* to training-zone-only actions until promoted to `certified`)
but doesn't strictly require it — could ship as an open-to-everyone
practice mode instead. Needs Phase 2 (and ideally Phase 3) mechanics to
exist first, or at least be designed in parallel with them the way §11 was
scoped in parallel with Phase 1's review gate.

---

### 7. K9-down dispatch integration hook
**What:** A small export/event (`qbx_k9unit:k9Downed` or similar) fired
when a certified, on-duty K9's health crosses a configurable threshold
(mirrors the exact threshold-check shape Phase 3's `HandlerDownDefense`
already needs for the *opposite* direction — handler health triggering K9
behavior). Any dispatch resource already running on the server can hook
it to raise a distinct "Officer K9 Down" alert, separate from a normal
player-down call.

**Why now:** Nowhere across all five phases does this spec mention
dispatch integration at all, despite it being one of the most commonly
requested companion features for comparable FiveM K9/PD resources (a K9
going down is treated as departmentally significant in PD RP, distinct
from an ordinary officer-down call). Phase 3 already has to build the
health-threshold-monitoring logic for `HandlerDownDefense` in the other
direction; this is a cheap mirror of that same logic, not new
infrastructure.

**Effort:** Small-medium once Phase 3/4 health-monitoring exists (mostly
just firing one more event off logic that already has to exist); doable
even earlier off raw `GetEntityHealth` polling if wanted sooner.

**Value:** High relative to effort — dispatch integrations are a
near-universal expectation in the FiveM PD resource ecosystem, and this
resource currently exposes zero exports at all (`README.md`: "There are
no exports declared by this resource").

**Dependency:** Cheapest once Phase 3's handler-down-defense health
monitoring exists to mirror, but not blocked on it.

---

## Tier C — lower urgency, still worth a line in the backlog

### 8. Long-term handler/K9 partnership record (as a convenience, not a
new access rule)
A lightweight `k9_partnerships` table (or a metadata field) recording a
*preferred* long-term partner for flavor/UX — e.g. the leash radial item
defaults to your registered partner instead of doing a nearest-player scan,
and it's a natural field for a future dispatch board ("K9 Rex — Handler
Smith — on duty") to read. Purely additive, never a substitute for the
existing per-attach consent flow. Small-moderate effort, moderate value —
mostly roleplay flavor and a minor usability improvement over
`FindNearestLeashCandidate()`'s current nearest-player scan (which will
misfire in a crowded MRPD lobby).

### 9. Certification expiry / periodic recertification
An optional, off-by-default `Config.CertificationExpiryDays` that marks a
cert as needing renewal after N days (real K9 units recertify
periodically). Small effort (one nullable `expires_at`-style check plus a
warning notification as it approaches), moderate value — good depth for
serious RP servers, skippable by casual ones. Touches the certification
table's status model (adds a third state beyond active/inactive: "active
but expired"), so route to db-schema before building, same as #2/#5.

### 10. Handler leaderboard / `/k9stats`
Once Phase 4's XP persistence (`k9_profiles` or metadata, per §6.5's own
open question) lands, a simple `/k9stats` command or NUI panel ranking
handlers by XP/successful searches/successful takedowns. Pure read against
data Phase 4 already has to persist — no new state, no new risk. Small
effort *after* Phase 4 ships, moderate value (leaderboards are a reliable
engagement/retention hook), zero value before Phase 4 exists to feed it.

---

## Ranked summary (value-for-effort, highest first)

1. **#1 K9 handler roster/admin UI** — buildable today, closes a gap the
   spec's own rationale already implied should exist.
2. **#3 Leash "Heel" recall command** — small, reuses existing pairing
   state, rounds out an already-shipped mechanic.
3. **#2 Revoke reason code** — small schema add, meaningfully deepens the
   audit trail SPEC.md already justified building.
4. **#7 K9-down dispatch hook** — small once Phase 3's health-threshold
   logic exists, closes a near-universal FiveM PD ecosystem expectation
   this spec never mentions.
5. **#5 Tiered certification** — medium effort, but time-sensitive: cheap
   now, expensive after Phase 3 hard-codes a boolean gate everywhere.
6. **#6 Training-mode sandbox** — medium effort, directly answers a real
   gap (no rehearsal path before live-consequence mechanics), pairs with #5.
7. **#4 Breed-specific stat modifiers** — cheap to decide now, payoff
   deferred to Phase 2/3/4.
8. **#9 Certification expiry** — small, optional depth for serious servers.
9. **#8 Long-term partnership record** — small-moderate, mostly flavor.
10. **#10 Handler leaderboard** — small, but has zero value until Phase 4
    ships the data it would read.

## Suggested next step
Hand #1 and #3 to **product-manager** as-is — both are small enough to
scope and build against current Phase 1 code with no other dependencies.
Flag #5 (tiered certification) to **product-manager** and
**economy-balance-agent** together *now*, before Phase 3 implementation
starts, given the "cheap now, expensive later" argument above — this is
the one item on this list with a real deadline. #2, #5, and #9 should all
get a **db-schema** pass before implementation since each changes the
`k9_certifications` table's invariants beyond what was already reviewed.
