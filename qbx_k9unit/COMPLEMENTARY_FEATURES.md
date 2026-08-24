# qbx_k9unit — Complementary Features & Ecosystem Integration

**Status correction (documentation pass, later the same day):** this
document's "Top 3" recommendations below have since all been built.
`server/exports.lua`/`client/exports.lua` (item 1), `server/admin.lua`
(item 2), and `server/tenure.lua` (item 3) all now exist, are listed in
`fxmanifest.lua`, and are documented as live in `README.md`. Read the
sections below as the reasoning that led to those features, not as a list
of still-open recommendations — in particular, the "Baseline worth stating
up front" paragraph immediately below ("`fxmanifest.lua` declares zero
exports") describes the state that motivated item 1 and is no longer true.

Author: technology-scout pass, 2026-08-24, jlwood17190665@gmail.com.

Purpose: a decision aid for the project owner, not a menu. Two questions:
(1) what real, named, external resources should this talk to, and (2) what
would make a K9 unit worth still running a month from now. Every item below
is checked against what's *actually* in this codebase today (read: `SPEC.md`,
`README.md`, `config.lua`'s `Config.Features`, `phase2_notes/
phase5_features_research.md`, `phase5_remaining_features_research.md`,
`dependency_and_audio_status.md`, `server/partnership.lua`,
`server/progression.lua`, `sql/install.sql`, `fxmanifest.lua`) so nothing here
re-proposes something shipped or already ruled out. `CameraFeedPiP` is not
re-proposed — it was correctly killed (an open, unresolved upstream
`citizenfx/fivem` issue asks for the exact render-target-to-NUI native this
would need; no native path exists).

**Baseline worth stating up front, because it changes the shape of every
ecosystem idea below:** `fxmanifest.lua` declares **zero exports** (no
`server_exports`/`client_exports`), and README says so explicitly —
"integration by other resources is currently limited to reading the
`metadata.k9certified` display flag... or listening for the [internal] net
events... these are internal contracts, not a stable public API." Every
external-resource integration idea below therefore has a shared prerequisite
that doesn't exist yet: **a real, documented export/event surface.** I've
called this out as its own item (#1) rather than burying it inside each
integration, because it's one small piece of work that unblocks several
"worth doing soon" items at once, and skipping it means every dispatch/MDT
idea below is really two tasks, not one.

---

## Top 3

1. **Ship a real export surface** (§1 below) — everything else in "ecosystem
   integrations" is blocked on this existing, and it's cheap.
2. **In-game admin/audit surface for certifications + partnerships + search
   log** (§4) — closes a gap that already exists today (the README's own
   "admin listing" is a raw SQL query, not anything in-game), costs almost
   nothing (read-only queries against tables that already exist), and admins
   will actually use it from day one, unlike most speculative features.
3. **Partnership-tenure bonuses on the registry that just landed** (§7) — the
   single best "reuses existing infrastructure" idea here: `server/
   partnership.lua` already has `established_at` and working accessors
   (`GetActivePartnerCitizenId`/`IsActivePartnerOf`) with *zero* gameplay
   consequence wired to them yet. This is the most direct way to make
   "who's my partner" matter without touching combat's still-blocked pieces.

---

# Part 1 — Ecosystem integrations

## 1. Give this resource a real export/event API — prerequisite, not optional

**What:** Formalize a small set of server exports/events: `OnK9SearchComplete`
(citizenid, target, result, weight, tier), `OnK9Certified`/`OnK9Decertified`,
`OnPartnershipEstablished`/`OnPartnershipEnded`, `OnXPTierReached`. All of
this data already exists in-memory or in a table (`k9_search_log`,
`k9_certifications`, `k9_partnerships`, `k9_progression`) — this is exposing
it, not computing anything new.

**Why it fits:** every "ecosystem integration" idea below (dispatch, MDT,
evidence) needs *some* way to react to a K9 event from outside this resource.
Today the only such surface is a client-side display-only metadata flag.
`Config.Combat.WantedStatusCheckOverride`/`IsPlayerDownedOverride` already
establish the right pattern (an override hook a server owner points at their
own resource) — this is the same idea applied to outbound events instead of
inbound checks.

**Needs:** `fxmanifest.lua` `server_exports`/`client_exports` block, a short
doc section, and wrapping existing internal `TriggerEvent`/DB-write call
sites to also fire the new public ones. No new file, no schema change.

**Effort:** small (touches `fxmanifest.lua` + a handful of existing files at
their existing success points).

**Blocker:** none technical. The only cost is committing to a stable contract
(README already flags internal events as "may change between phases" — a
real export surface means picking a shape and keeping it).

**Hand-off:** coder-architect (manifest + contract), coder-backend for the
call-site wiring.

---

## 2. Dispatch integration (cd_dispatch / ps-dispatch / qs-dispatch)

**Verified:** `Project-Sloth/ps-dispatch` is a real, actively developed
(356 commits, open PRs), QBCore-**and**-QBX-compatible dispatch/alert
resource with its own exports (`CustomAlert`/`SendTargetedAlert` per a
third-party integration's usage). `config.lua`'s own
`WantedStatusCheckOverride` comment already names `cd_dispatch`/`ps-dispatch`/
`qs-dispatch` as the three ecosystem-common options precisely because they
differ — I independently confirmed `ps-dispatch` is real and current this
session; I could **not** independently confirm `cd_dispatch`'s or
`qs-dispatch`'s exact current canonical repo/maintenance status this session
(search results point at several forks/mirrors, no single authoritative one
surfaced) — treat those two as "named by convention, not independently
re-verified," not as confirmed-current.

**What it would do:** two directions, both currently absent:
- **Outbound:** a completed contraband search (`server/search.lua`'s
  `found`/`clean` result, already logged to `k9_search_log`) or a bark alert
  fires a dispatch call ("K9 alert — contraband found") so non-K9 officers
  see it on the dispatch board instead of only the searching K9 knowing.
- **Inbound (already scaffolded, unused):** `Config.Combat.
  WantedStatusCheckOverride` exists specifically so `BiteAndHold`/
  `NonLethalTakedown`'s player-target path can ask a real dispatch/wanted
  system instead of guessing off `metadata.wanted`. Today it's `nil` — no
  server has ever pointed it anywhere because those two features have no
  in-game entry point yet.

**Needs:** item #1's export surface (outbound), plus documentation for a
server owner to write the ~10-line inbound override function against
whichever dispatch resource they run.

**Effort:** small once #1 exists. Inbound direction has zero cost to this
resource itself — it's a config value a server owner fills in.

**Blocker:** the inbound half is dead weight until `BiteAndHold`/
`NonLethalTakedown` get an in-game trigger (still true per `CHANGELOG.md`'s
Known Limitations) — don't invest further here until that lands.

**Hand-off:** coder-backend for the outbound alert; note for
native-api-assistant that this doesn't touch framework internals, it's a
plain `TriggerEvent` to whatever the server owner's dispatch resource
expects.

---

## 3. MDT / evidence integration (ps-mdt, or an equivalent)

**Verified:** `Project-Sloth/ps-mdt` is real, actively developed (600
commits), works on **QBCore and Qbox** via its own `ps_lib` abstraction, and
— directly relevant — already ships evidence tracking ("Register evidence
with type, serial, and location... track chain of custody, link to cases and
reports") plus real server exports (`IsCidFelon`, `registerWeapon`,
`GetCitizenPhoneNumber`).

**What it would do:** `k9_search_log` is described in this codebase's own
README as existing "purely for dispute accountability... nothing in this
resource ever reads it back." That's a real, named gap: a completed search
that finds contraband on a specific citizen currently produces a DB row and
nothing else visible to police paperwork. Feeding a `found` result into an
MDT's evidence/report system (via item #1's export, or directly via
`ps-mdt`'s exports if standardizing on it) turns "the K9 found drugs" into an
actual case artifact an officer can cite, instead of a fact only recoverable
by hand-querying the database.

**Needs:** item #1's export, plus a small adapter resource or config hook
naming which MDT's API to call (mirrors the dispatch override pattern —
MDTs are not interchangeable any more than dispatches are).

**Effort:** small-to-moderate. The data already exists; this is plumbing it
to one more consumer, not computing anything new.

**Blocker:** `SearchZones`/`ContrabandAlerts` are themselves still `false` by
default (reviewed and safe to enable, but not yet live on any real server per
this codebase's own status) — sequence this after a server actually turns
those on, not before.

**Hand-off:** coder-backend, db-schema if the adapter wants to denormalize
anything (it shouldn't need to — `k9_search_log` already has what's needed).

---

## 4. Jail / corrections — weaker fit, worth naming why

**Verified:** the official `Qbox-project/qbx_prison` is explicitly marked
**"Not Maintained"** — do not build against it. `Qbox-project/qbx_police`
ships an integrated jail system as part of the standard Qbox police
resource. Third-party alternatives (`xT-Development/xt-prison`, "Pickle
Prisons") exist and claim Qbox support but weren't source-verified this
session.

**Honest assessment:** unlike dispatch/MDT, there's no clean, direct hook
here. A K9 search result doesn't jail anyone by itself — an officer still has
to make an arrest and file charges through whatever system handles that
(normally the MDT, not the jail resource directly). Routing K9 evidence
*through the MDT integration (§3)* already gets it in front of the officer
at charge time; a *separate* direct K9-to-jail-resource integration would
just be duplicating that path against a resource that's less standardized
across servers than either dispatch or MDT. **Recommend not building a
dedicated jail integration** — treat MDT (§3) as the one real integration
point or corrections-relevant data, and note this conclusion so nobody
re-investigates it expecting a different answer.

---

## 5. Ambulance / laststand — good news: probably already covered

**Verified:** `Qbox-project/qbx_ambulancejob` (EMS job) and
`Qbox-project/qbx_medical` (the actual health/death/laststand state) are
both real, active Qbox-project repos — `qbx_medical`'s own issue tracker
shows live work on "dead states"/laststand as of this session.
`Config.Combat.PropDragging.IsPlayerDownedOverride` already exists for
exactly this class of integration, currently `nil`.

**The actual finding, worth stating plainly:** the K9 **is a player's own
persistent character** (`SPEC.md` §1 — this resource's own foundational
design decision). That means when a K9 player takes lethal damage, whatever
laststand/revive system the server already runs for every other player
(`qbx_medical`) already applies to them with **no integration work needed**
— there's no separate "K9 health system" to reconcile. The one place this
resource's own combat code (`server/combat.lua`) needs a *check* rather than
automatic coverage is asking "is this **target** currently downed" before a
takedown/bite-hold — which is exactly what `IsPlayerDownedOverride` is
already built for. Point it at `qbx_medical`'s own downed-state export once
one exists and is confirmed (its own issue tracker shows this is an area
still being refined upstream, so confirm the exact export name against a
live install rather than guessing).

**Needs:** nothing new to build — a config value, once `qbx_medical` is
confirmed to expose a stable "is this player downed" read and once
`BiteAndHold`/`NonLethalTakedown` actually have an in-game trigger.

**Effort:** trivial. **Blocker:** same as §2's inbound half — no in-game
trigger for the features that would consume it yet.

---

## 6. K9 equipment shop — cheapest "integration," barely one

**What:** register a "K9 Supply" shop via `ox_inventory`'s own `RegisterShop`
(already a hard dependency, no new resource needed) selling the item names
this codebase has **already invented and left as placeholders with nowhere
to buy them**: `k9_treat` (Mood), `k9_meat_bait`/`k9_ultrasonic_whistle`
(Distraction), `k9_medkit` (K9Medkit). Right now these are config strings
with no source anywhere on a fresh install — if a server owner enables the
wellbeing subsystem today, there is nothing to actually buy.

**Why it fits:** this isn't a new integration so much as finishing one that's
half-built — `ox_inventory` is already required, already loaded, already
does shops. This is the single cheapest item in this whole document.

**Needs:** one small config table + `RegisterShop` call at resource start
(server-side), item definitions in the target server's own `items.lua`
(same "you must add these to your own item table" caveat every placeholder
item in this codebase already carries).

**Effort:** small. **Blocker:** none — only needs someone to decide prices/
stock, which is a config-validator-adjacent call once the wellbeing flags
are closer to a go-live review.

**Hand-off:** coder-backend; config-validator should weigh in on pricing
once wellbeing's other placeholder numbers get their review pass, since
item cost interacts with how punishing the Mood/Distraction penalties feel.

---

# Part 2 — Gameplay depth for the long haul

## 7. Partnership-tenure bonuses ★ (top 3)

**What it is:** `server/partnership.lua` (landed this pass) tracks
`established_at` per active partnership and exposes
`GetActivePartnerCitizenId`/`IsActivePartnerOf` — but wires **zero**
gameplay consequence to it (its own header says so explicitly: "a FOUNDATION
only... no combat consequence wired to it yet"). Add a small, passive bonus
that scales with **how long the current partnership has been active**: e.g.
a Mood regen bonus or a raised Fatigue cap while a real partner is nearby and
the partnership has existed past some threshold (a day, a week — read from
`established_at`).

**Why it fits this resource specifically:** this is the most literal reading
of "give the partnership registry that just landed something to do." It also
directly answers the brief's ask for "handler-K9 bonding" — right now
there's a table that *records* a relationship but nothing in the game reacts
to it existing at all.

**Needs:** a read of `established_at` (already a column) inside
`server/wellbeing.lua`'s existing tick loop (already iterates active K9s),
feeding into the same `RecomputeK9MoveRate`/`K9MoveRateModifiers` composer
the five wellbeing stats already use — no new file, no new table, one new
modifier key.

**Effort:** small-moderate — this is exactly the kind of "add one more input
to an existing composer function" change this codebase's own conventions
already support.

**Blocker:** `HandlerPartnership` and the wellbeing flags it would touch are
both still `false` by default and unreviewed for balance — this is a design
worth speccing now, but numeric values need the same config-validator pass
every other Phase 4 number is already waiting on.

**Hand-off:** product-manager to spec the exact curve/thresholds,
config-validator for the numbers, coder-backend to implement.

---

## 8. Give XP tiers real unlocks, not just multipliers

**What it is:** `Config.XPTiers` today only changes `speedMultiplier` and
`scentRange` — two numbers, invisible to the player except as a slightly
faster dog. Nothing about crossing a tier is *visible* or *unlockable* in the
way tiered progression systems usually are. Add real, checkable unlocks per
tier that reuse systems that already exist: e.g. Trained unlocks the
`AdvancedBarkRadial` variant set (today gated only by a flag, not by any
in-game achievement), Veteran reduces `K9Medkit.cooldownMs` or raises a
wellbeing stat's `max`, Elite unlocks a cosmetic HUD badge (the NUI bridge
`client/hud.lua`/`html/app.js` already exists and already renders per-K9
state).

**Why it fits:** the XP/tier table and the wellbeing/HUD/bark-radial systems
already exist independently — this connects them instead of adding a new
subsystem. It's the most direct answer to "give the XP tiers something
meaningful to unlock."

**Needs:** extending `Config.XPTiers`' row shape with a couple more fields,
and a handful of `if playerTier >= X then` checks at the points those other
systems already gate on their own flags. No new table (tier is already
persisted via `k9_progression`'s `xp` column).

**Effort:** small-moderate, mostly reads (checking a tier at each existing
gate point) rather than new logic.

**Blocker:** depends on which systems get referenced — if it reaches into
`AdvancedBarkRadial`, it inherits that feature's own real cost (still-
placeholder audio, per `phase5_features_research.md` §1) for the *unlock* to
feel like anything; recommend picking unlocks from systems that already have
real, audible/visible effects (HUD badge, medkit cooldown, wellbeing caps)
first, and treat bark-variant unlocks as a nice-to-have once real audio
exists, not before.

**Hand-off:** product-manager for the exact unlock list, coder-backend/
coder-frontend for the HUD badge piece.

---

## 9. In-game admin/audit surface

**What it is:** today, "list all certified handlers," "who's currently
partnered with whom," and "review the search log" are all things this
resource's own README documents as a **raw SQL query** an admin runs by
hand. There is no in-game command or menu for any of it, despite three
tables (`k9_certifications`, `k9_partnerships`, `k9_search_log`) that already
carry exactly this data.

**Why it fits:** this is the textbook "happy path with no admin
counterpart" the brief asks to look for — certification grant/revoke has a
rich, reviewed flow; certification *oversight* has none. It costs almost
nothing because every query already exists in the README as documentation —
this just wraps them in a command/ox_lib menu instead of leaving them as a
copy-pasteable SQL string.

**Needs:** one new admin-gated command (ACE permission, not job/grade — this
is server-operator tooling, not a K9-handler feature) plus read-only queries
against tables that already exist. No schema change.

**Effort:** small. This is the best value-per-effort item in this whole
document precisely because it needs zero new data.

**Blocker:** none technical — only needs an ACE-permission convention
decision (this resource currently gates everything by job/grade, never ACE,
so this would be the first ACE-gated surface; flag that as a small
precedent-setting choice, not a blocker).

**Hand-off:** coder-backend; flag the ACE-vs-job-grade precedent to
coder-architect since it's a first for this resource's access-control
conventions.

---

## 10. Cooperative search bonus for partnered K9s

**What it is:** when two K9s who are active partners (`server/
partnership.lua`) both participate in resolving the same search/track
(e.g. one finds the trail, the other completes the contraband search), grant
a small joint XP or Mood bonus over what either would get solo.

**Why it fits:** ties three already-shipped systems together (partnership
registry, XP awards in `server/progression.lua`, and `server/search.lua`'s
existing success path) without adding a new one. Gives partnered play an
actual mechanical reason to exist beyond a bonding-flavor bonus (§7) — a
reason to *do things together*, not just stand near each other.

**Needs:** `server/search.lua`'s existing success branch checking
`IsActivePartnerOf` against whoever else is nearby/recently active on the
same target, then calling the existing `AwardXP` a second time with a
different (smaller) amount for the partner.

**Effort:** small — reuses three existing call sites, adds one new
conditional branch.

**Blocker:** needs a product decision on exactly what "cooperative" means
here (same search, same session, physically both present?) — worth a short
spec pass, not a design fork on the scale of Phase 3's cross-cutting forks.

**Hand-off:** product-manager for the trigger definition, coder-backend to
implement.

---

## 11. Certification specializations (beyond binary certified/not)

**What it is:** `k9_certifications` today is a single binary flag per
(citizenid, job). Real K9 units train for specialties (narcotics,
explosives, patrol/apprehension). Add a `specialization` column, and gate
`Config.SearchContrabandItems` by splitting it into per-specialization lists
— a narcotics-only-certified K9 finds drugs but not weapons, etc.

**Why it fits:** this is the most direct answer to "training/certification
progression beyond the current binary certified flag" — it extends a schema
this codebase's own db-schema agent already reviewed once, rather than
inventing a parallel system.

**Needs:** one column on `k9_certifications` (or a small sibling table if
multiple specializations per citizen should stack — a real design choice),
splitting `Config.SearchContrabandItems` into named buckets, and a check in
`server/search.lua`'s existing contraband-matching logic.

**Effort:** moderate — touches a reviewed table (needs the same care
`k9_certifications`' original schema review got) and the security-reviewed
`server/search.lua`, not a small-surface change.

**Blocker:** this is a genuine design fork (single specialization vs.
multiple, whether it changes the certify-grant flow's own eligibility
checks) — route through db-schema before touching the schema, and
config-validator before touching contraband-item buckets (this is exactly
the "touches money/items/progression" case the brief calls out).

**Hand-off:** db-schema first, then coder-backend; config-validator on the
item-bucket split.

---

## Ideas considered and not recommended

- **A K9 obstacle-course time trial / leaderboard.** Appealing on paper
  (reuses `AgilityAdvanced`'s vault system, gives competitive players
  something to chase), but `AgilityAdvanced` itself ships behind an
  unreviewed, still-placeholder tuning table (`maxVaultHeight`/
  `vaultCooldownMs` both marked UNTUNED in `config.lua`) — building a
  leaderboard on top of a mechanic whose own feel isn't settled yet means
  re-tuning the base mechanic later would invalidate the leaderboard's own
  numbers. Worth revisiting **after** `AgilityAdvanced` gets its balance
  pass, not before — noting it here so it isn't silently dropped, not
  recommending it now.
- **A dedicated jail/corrections resource integration** — see §4 above;
  concluded the MDT integration already covers the real use case better
  than a second, parallel path would.
- **A "K9 walk"/idle downtime activity with no mechanical effect.** Doesn't
  clear the bar — this resource already has Pet/Feed (Mood) as a genuine
  downtime interaction with a real stat effect; adding a second, cosmetic-
  only idle action would be strictly weaker than extending the one that
  already has consequence (§7/§8's directions do that instead).
- **Re-scoping `FetchMechanic`/`PropAttachments` as "gameplay depth."** Both
  are real, already-researched Phase 5 items with a concretely identified
  remaining blocker (an animal-ped bone **index**, not name, findable only
  by an in-engine sweep — see `phase5_remaining_features_research.md` §2).
  Not re-litigated here since that research already exists and already
  names the exact next step; flagging only so it isn't mistaken for a new
  finding.

---

## Sources

- [Project-Sloth/ps-dispatch](https://github.com/Project-Sloth/ps-dispatch)
- [Project-Sloth/ps-mdt](https://github.com/Project-Sloth/ps-mdt)
- [Qbox-project/qbx_ambulancejob](https://github.com/Qbox-project/qbx_ambulancejob)
- [Qbox-project/qbx_medical](https://github.com/Qbox-project/qbx_medical)
- [Qbox-project/qbx_prison](https://github.com/Qbox-project/qbx_prison) (confirmed "Not Maintained")
- [Qbox-project/qbx_police](https://github.com/Qbox-project/qbx_police)
- This codebase's own `SPEC.md`, `README.md`, `config.lua`, `fxmanifest.lua`,
  `server/partnership.lua`, `sql/install.sql`,
  `phase2_notes/phase5_features_research.md`,
  `phase2_notes/phase5_remaining_features_research.md`,
  `phase2_notes/dependency_and_audio_status.md`,
  `phase2_notes/phase3_handler_partnership_decision.md`
- `cd_dispatch` and `qs-dispatch`'s exact current canonical repos were **not**
  independently confirmed this session (search results surfaced multiple
  forks/mirrors, no single authoritative source verified directly) — named
  only because `config.lua` already references them by convention; treat as
  unconfirmed, not as verified the way `ps-dispatch`/`ps-mdt`/the Qbox-project
  repos above are.
