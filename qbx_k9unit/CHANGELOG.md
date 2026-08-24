# Changelog

All notable changes to `qbx_k9unit` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Phase 2 (tracking, contraband search, vision, door interaction) has landed
on this branch as a complete feature set with real client and server
implementations, but it has **not** been through the same release-readiness
pass Phase 1 got before shipping — there is no version bump yet. Since Phase
2 landed, this branch has also picked up scent tracking's previously-missing
server-side source resolution, a resource-wide cooldown/mutex refactor, a
`luacheck` CI job, the certification-revocation TOCTOU fix below, three
native-correctness corrections, door interaction's previously-deferred
nudge-open half, and the first (still feature-flagged-off) slice of Phase
4's vitality HUD. Phase 3 (combat/action features) now has a code-complete
`BiteAndHold`/`NonLethalTakedown` implementation — both `server/combat.lua`
and its previously-missing `client/combat.lua` counterpart exist and are
registered in `fxmanifest.lua` — but it is still **not reachable by any
player**: nothing calls `client/combat.lua`'s exposed `RequestBiteHold()`/
`ReleaseBiteHold()`/`RequestTakedown()` globals (not the radial menu, not
an ox_target option, not a command), and both feature flags still ship
`false`. Writing the client half also found and fixed a real safety bug:
`SetEntityCanBeDamaged` is confirmed client-only, so `NonLethalTakedown`'s
NPC-target branch calling it server-side was a silent no-op — a
"non-lethal" takedown against an NPC could actually kill it before this
fix, closed by relaying that native (and the equivalent bite-hold
suppression natives, whose server-side validity could not be confirmed
either way) to the requesting K9's own client instead. `PHASE3_SPEC.md`
has been revised (Revision 3: player-vs-player K9 combat is now a settled,
in-scope design decision, reversing an earlier NPC-only default), and the
handler-partnership design fork (originally named as blocking both
`BiteAndHold`'s Recall actor and `HandlerDownDefense`'s trigger) has since
been resolved as a design decision — a new, dedicated partnership
registry, not a reuse of the existing leash pairing — but that resolution
is still a decision document, not code: `server/partnership.lua` does not
exist (only its `k9_partnerships` schema does), so Recall and
`HandlerDownDefense` remain uncoded and `Config.Features.HandlerDownDefense`/
`BiteAndHold`/`NonLethalTakedown` must all stay `false`. Since that Phase 3
design work landed, this branch has also picked up: a shared, defensive
netId-to-entity resolver extracted out of two independent hand-written
copies; the first three real Phase 4 capability grants beyond the vitality
HUD (a certified/departmental K9 gear stash, a server-authoritative K9
medkit, and a unified Fatigue/Mood/FearStress/Distraction/Injury wellbeing
subsystem feeding a new XP/progression system); and the first two real
Phase 5 features (a deployable kennel R&D scaffold, and an expanded bark
radial). **Every one of these new features ships behind its own
`Config.Features.*` flag, and every one of those flags still defaults to
`false`** — none of it is active on an existing install. Since those
features landed, this branch has also picked up a further round of
correctness/security fixes, covered in detail below: the previously-missing
`k9_progression` persistence table now exists in `sql/install.sql`; the
XP-award pipeline for search/tracking — previously dead code, since
nothing anywhere actually called `AwardXP` despite `config.lua`'s own
comment claiming a call site existed — is now really wired up, alongside a
new distance gate closing a stationary-farm exploit that wiring introduced;
the FearStress wellbeing stat's gunfire input now dedupes by reporting
source, closing the primary amplification vector (one sustained forged
reporter can still hold a K9's stress elevated, a disclosed residual risk —
see Known Limitations); and `Config.K9Inventory.accessScope` is now
hard-enforced to `'department'` by a resource-start assertion, closing a
real access-control gap in the previously-documented `'ownerOnly'` value
(see Security below). Everything below is pending final packaging.

### Added

- **Scent/blood/gunpowder tracking** — a certified handler can start a
  self-following trail for any of the three configured scent types from a
  new "K9 Unit" radial submenu entry per type (Track Scent / Track Blood /
  Track Gunpowder), each an independent start/cancel toggle gated by its
  own `Config.Features` flag. Trails render as ground markers with
  configurable spacing and decay across water crossings, cutting off
  cleanly at the water's edge rather than vanishing outright.
- **Scent trail source resolution (`server/tracking.lua`)** — closes the
  gap the previous entry in this file flagged as an explicit, disclosed
  "can never functionally succeed" blocker. A real, first-party
  `ox_inventory` server-side hook,
  `exports.ox_inventory:registerHook('swapItems', ...)`, now feeds a
  ground-drop's coordinates into the same `TrackableLog`/nearest-source
  lookup blood and gunpowder already used, so "Track Scent" can now
  actually resolve to a real dropped-item location instead of always
  reporting "not found." The hook fires server-to-server (never a
  client-triggerable event), so unlike blood/gunpowder's relay events it
  has no "forged trail" acceptable-risk framing to write — the reported
  source can't be spoofed by a modified client the way a fabricated damage
  or weapon-fire report could be.
- **Contraband search** — a certified handler can search a nearby vehicle
  or person via ox_target ("Search Vehicle" / "Search Person"), with the
  server performing the real, container-recursive inventory read and
  returning a found/clean/failed result. Searches are rate-limited on two
  independent cooldowns, and any bystander-facing contraband alert is
  distance-filtered to nearby players in the search zone rather than
  broadcast server-wide.
- **Search audit log** — every completed search attempt (found, clean, or
  failed) is now written to a new `k9_search_log` table for dispute
  accountability. Early rejections (too far, on cooldown, etc.) are never
  logged, since they never actually touch the target.
- **Thermal and night vision** — togglable vision modes for any player while
  playing a configured K9 character. Deliberately gated on the K9 model
  alone, not certification — treated as innate perception, not a granted
  departmental privilege.
- **Door interaction (scratch-to-alert + nudge-open)** — a certified
  handler can scratch at a nearby door-like object via ox_target to
  broadcast an alert sound to everyone with that door streamed in
  (server-authoritative: `server/main.lua` independently resolves,
  existence-checks, and proximity-checks the claimed door before ever
  broadcasting, never trusting the client's own door guess). A second,
  separate "Nudge Door" ox_target option on the same objects has now
  landed too, previously deferred as out of scope for Phase 2's first
  drop. Its safety design is deliberate and non-negotiable: it never calls
  any door-lock/CDoor native and never reads, writes, freezes, or moves
  the door entity in any way — the only real-world safe design available,
  since most door-lock resources manage their own lock flag entirely
  outside GTA's native door system, so treating "not registered there" as
  "unlocked" would be a real bypass, not a theoretical one. The feature's
  only actual effect is a cosmetic push impulse and sound applied to the
  K9's own ped (never the door), gated purely by interaction distance and
  `CanShowK9UI()`. It has **zero server involvement** — no
  `TriggerServerEvent`, no callback, nothing server-authoritative touched
  anywhere in the implementation.
- **Full Phase 2 config schema** — `Config.Tracking`, `Config.SearchZones`,
  `Config.SearchContrabandItems`, `Config.DoorInteraction`,
  `Config.Vision`, and related tuning tables, plus a `Config.Features`
  flag per Phase 2 feature so each can be enabled independently once ready.
  New `ox_inventory` dependency (required by contraband search).
- **Resource-start config safety check** — the resource now refuses to
  start if `Config.DoorInteraction.nudgeRequiresUnlocked` has been set to
  `false`. It's documented as a hard safety requirement (nudge-open must
  never be able to bypass a locked door), not a server-tunable option, so
  a bad value now fails loudly at startup instead of silently allowing a
  future lockpick-equivalent bypass. Now that nudge-open has actually
  landed (see the Added entry above), this assertion — not a runtime
  branch inside the feature itself — is the full extent of how this field
  is enforced: nudge-open has no real lock-state read anywhere for it to
  meaningfully gate, by design, so a future implementer would have to
  deliberately remove this assertion before wiring a real (dangerous)
  lock-state branch off it.
- **Shared cooldown/TTL/mutex helper (`server/cooldowns.lua`)** — a pure
  structural extraction, not a redesign. The 11 independent hand-rolled
  cooldown/mutex tables that had accumulated across `server/main.lua`,
  `server/certifications.lua`, `server/tracking.lua`, and `server/search.lua`
  now build on three shared constructors: `NewCooldown` (flat
  `key -> lastTouchedAt`, covers 9 of the 11 — bark, leash-request,
  door-scratch, certify-action, damage/weapon-fire relay, and search
  cooldowns), `NewNestedCooldown` (the two-level per-source/per-track-type
  shape `server/tracking.lua`'s scent/blood/gunpowder query cooldown
  needs), and `NewMutex` (the plain acquire/release lock
  `server/search.lua`'s in-flight guard needs). Every migrated call site
  keeps its exact original threshold, key shape, and cleanup timing
  (`playerDropped` handler or periodic sweep, matching whichever the
  original table used) — behavior is unchanged, only the duplicated
  bookkeeping code across four files is not. Loaded first among this
  resource's own `server_scripts`, since the other four files call these
  constructors at their own file-load time.
- **Added `luacheck` to CI**, alongside the existing `luac5.4 -p` syntax
  check (`.github/workflows/lua-check.yml`), configured via a new
  repo-root `.luacheckrc` with a curated `read_globals` list of the real
  FiveM/CFX natives this resource actually calls and a `globals` list of
  its own cross-file globals (`Config`, `NewCooldown`/`NewNestedCooldown`/
  `NewMutex`, `HasK9Access`, etc.) so real, intentional patterns aren't
  flagged as undefined/unused. `unused_args` and `max_line_length` are
  deliberately left off, with the reasoning documented inline in
  `.luacheckrc` itself. The one real finding it surfaced — an "empty if
  branch" warning (542) on `client/search.lua`'s deliberately-silent
  `on_cooldown`/`search_in_progress` UX branch — turned out to be a false
  positive, not a bug, and is suppressed with an inline
  `-- luacheck: ignore 542` comment rather than "fixed" by changing
  behavior.
- **Phase 4 vitality HUD (`client/hud.lua`, still off by default)** — this
  resource's first NUI surface: a passive, always-visible-while-relevant
  overlay showing health/stamina/hunger/thirst for the active K9
  character, gated by the new `Config.Features.HealthStaminaHUD` flag
  (ships `false`). Visibility uses the same `CanShowK9UI()` gate (K9 model
  **and** live server-side access check) the radial menu already uses —
  this HUD is treated as a department-issued monitoring instrument, not
  the K9's innate perception, so unlike thermal/night vision it does
  **not** display for an uncertified player just because they're
  K9-modeled. Pushes to the NUI are change-threshold- and
  heartbeat-driven rather than a fixed poll broadcast, to avoid spamming
  `SendNUIMessage`, and the overlay never calls `SetNuiFocus` — it has no
  interactive element to focus, by design. Wired into `fxmanifest.lua`
  (`ui_page`, `html/index.html`/`style.css`/`app.js`) but genuinely inert
  end-to-end while the flag stays `false`.
- **Shared defensive netId-to-entity resolver (`server/entities.lua`,
  `ResolveNetworkEntity`)** — a pure structural extraction, not a redesign.
  The two independent hand-written copies of "resolve a client-claimed
  network id to a live entity, then existence-guard it" (`server/main.lua`'s
  `relayDoorScratch` and `server/search.lua`'s `HandleSearchTarget`) now
  share one function, with each call site's own additional checks (the
  door-scratch handler's object-only restriction; the search handler's
  target-type cross-check) left exactly where they were. One small,
  disclosed strengthening came along for the ride: `HandleSearchTarget`
  previously accepted a nonzero `NetworkGetEntityFromNetworkId` result
  without also confirming `DoesEntityExist`; the shared resolver now applies
  that same existence check to every caller, including this one — not
  expected to change observed behavior, but a real, deliberate tightening
  rather than a silent one.
- **K9 Inventory (`Config.Features.K9Inventory`, still `false`)** — a
  certified K9's own `ox_inventory` gear stash, opened via an ox_target
  "Open K9 Gear" option on the K9's own ped. The K9 can always open their
  own stash; who else can is controlled by `Config.K9Inventory.accessScope`,
  which is **hard-locked to `'department'`** (any player whose job is a key
  in `Config.Departments`, any grade) by a resource-start `assert` in
  `server/inventory.lua` — setting it to anything else crashes the resource
  at startup by design, it is not a selectable runtime option with a
  caveat. There is **no working "K9's own citizenid only" mode**, and there
  never was one: a security review traced `ox_inventory`'s real stash-access
  path and found it is gated *exclusively* by `stash.groups` via
  `server.hasGroup(...)` — both real check sites are written
  `stash.groups and ... and not hasGroup(...)`, so the `nil` groups value
  the previously-documented `'ownerOnly'` setting produced short-circuited
  straight to **allow, for every caller, unconditionally**. `RegisterStash`'s
  `owner` argument (the thing `'ownerOnly'` actually set) is used
  exclusively for `Inventories` table keying and DB persistence in
  `ox_inventory` — it is never compared against the requesting player's own
  identity anywhere in that dependency, and `ox_inventory`'s own upstream
  docs describe the boolean-owner form as explicitly allowing a player to
  "request other player's stashes," so this was never a bug in
  `ox_inventory` to rely on being fixed. Net effect: once any K9's stash
  had been registered in a session, **any connected player who knew or
  guessed that K9's citizenid could open it directly from a modified
  client with full read/write access**, bypassing proximity, `HasK9Access`,
  this resource's own cooldown/mutex, and the feature flag itself. There is
  also no `ox_inventory` mechanism available to build a real per-owner ACL
  from — `groups` is the only access-control primitive its stash system
  actually provides — so a genuine "K9's own citizenid only" mode is not
  currently implementable against this dependency at all, not merely
  unbuilt; see `server/inventory.lua`'s header for the full trace and the
  `RegisterStash`/`hasGroup` source citations. Item-whitelist enforcement
  (`Config.K9Inventory.allowedItems`) is **not** implemented this pass and
  currently has no effect even if set — left honestly inert rather than
  a half-built enforcement path.
- **K9 Medkit (`Config.Features.K9Medkit`, still `false`)** — a "Treat K9"
  ox_target world interaction letting a department member or a configured
  EMS-job player (`Config.K9Medkit.emsJobs`) use a real, consumed
  `ox_inventory` item on a nearby K9-model player to restore health, on a
  per-K9 cooldown. Deliberately **not** gated on the using player's own K9
  certification — treating a K9 is not itself a K9-handling action.
  Restoring health is applied by the target's own client self-writing an
  already-clamped, server-computed absolute value (never a delta it could
  reapply), since a cross-owner `SetEntityHealth` write was not confirmed
  reliable server-side this pass. Also restores the new wellbeing
  subsystem's Injury stat once that subsystem exists — a forward-compatible
  no-op until it does.
- **Unified K9 wellbeing subsystem (`Config.Features.FatigueSystem` /
  `MoodSystem` / `FearStressSystem` / `DistractionSystem` / `InjuryLimping`,
  all still `false`)** — one shared per-citizenid stat store and one shared
  server tick drive five independently-toggleable stats for a K9 character:
  Fatigue (decays while sprinting, recovers while idle, reduces move speed
  when low), Mood (decays on taking damage, restored by "Pet K9"/"Feed K9"
  ox_target interactions, reduces move speed when low), Fear/Stress (rises
  near recent gunfire, imposes a temporary command-hesitation state above a
  threshold, reducible via a "Calm Down" self-action — its gunfire input now
  dedupes by reporting source rather than counting raw relayed events,
  closing the primary way one spamming/forged report could multiply a
  nearby K9's stress far past what one real continuous shooter would cause;
  a single sustained forged reporter can still hold a K9's stress/hesitation
  elevated indistinguishably from genuine continuous nearby gunfire, a
  disclosed residual risk, not something this pass claims to have fully
  closed — see Known Limitations), Distraction (a
  thrown meat-bait item or an ultrasonic whistle — deliberately usable by
  *any* player, not just K9 handlers, since a fleeing suspect using one
  against a pursuing K9 is an intended use case — briefly breaks command),
  and Injury (decays on taking damage, restored by the K9 medkit above,
  blocks sprint/jump input and reduces move speed below configured
  thresholds). Every stat is only ever ticked, read, or gated behind its own
  feature flag — a disabled stat idles at its healthy default and costs
  nothing. Flashbang immunity for Distraction
  (`Config.Wellbeing.Distraction.flashbangImmune`) is aspirational config
  only, **not implemented** — it depends on an unconfirmed third-party
  flashbang/stun resource's own event shape.
- **XP / progression (`Config.Features.XPProgression`, still `false`)** —
  server-authoritative XP accumulates per K9 citizenid, persisted in the
  `k9_progression` table (survives a department change). **That table was
  missing from `sql/install.sql` until this pass** — every
  `server/progression.lua` query against it was pcall-wrapped, so this
  never crashed the resource, it just meant no K9's XP ever actually
  survived a restart or reconnect; the table now exists (see Database
  above). Separately, **the `AwardXP` calls themselves were previously dead
  code**: `config.lua`'s own comment on `searchContrabandFound` already
  described a call site in `server/search.lua`, but nothing anywhere had
  actually wired it up, so no K9 could earn XP from a search or a resolved
  track regardless of this flag — both call sites (`server/search.lua`,
  `server/tracking.lua`) now really call it. XP accrues from a successful
  contraband find (Phase 2 search) and actually arriving at a resolved
  scent/blood/gunpowder trail source (Phase 2 tracking) — arrival, not just
  a trail resolving, is required, closing an otherwise-farmable "trigger a
  search and never finish it" loop. Wiring the arrival award up also
  introduced, and this same pass also closed, a second farm vector: a K9
  already standing at (or who forges) a source's location could otherwise
  round-trip resolve→report-arrival for free XP with zero travel;
  `server/tracking.lua` now requires at least 15m of live distance between
  the K9 and the source at resolve time before an arrival ticket is even
  created (the cosmetic trail reveal itself is unaffected). Crossing a
  threshold in `Config.XPTiers` immediately applies that tier's speed
  multiplier and scent range and pushes a one-time "tier reached"
  notification to the K9's own client. The two Phase 3 award hooks
  (`biteHoldSuccess`, `takedownSuccess`) are now wired to real call sites in
  `server/combat.lua`, but stay dormant in practice — `BiteAndHold`/
  `NonLethalTakedown` still ship `false` and have no in-game trigger at all
  (see Known Limitations).
- **Deployable kennel (`Config.Features.DeployableKennel`, still `false`,
  Phase 5 R&D scaffold)** — a certified handler can place a world kennel
  object near themselves (`/k9deploykennel`) and pick it up again via an
  ox_target option on the placed object. The server, never the client,
  computes the spawn point from the handler's own live position, and
  independently re-validates the placed object's model/type/position before
  accepting it as real — a modified client cannot report an arbitrary
  pre-existing networked entity as "the kennel it just placed." Limited to
  one active kennel per handler (a hardcoded invariant, not a config value),
  with cleanup on pickup, disconnect, and resource stop. The kennel prop
  model itself (`prop_doghouse_01`) is a single-source, unconfirmed lead;
  a confirmed-real fallback prop is used automatically if it fails to load.
- **Advanced bark radial (`Config.Features.AdvancedBarkRadial`, still
  `false`, layered on top of `Config.Features.BasicBarkSounds`)** — the
  radial menu's single "Bark" action becomes a submenu of three variants
  (Alert/Aggressive/Calm, `Config.AdvancedBarkRadial`), each sending the
  same existing `relayBark` event with a different `barkType` string;
  `server/main.lua`'s handler is unchanged, since it already accepts any
  opaque, length-capped bark type. **This adds three more placeholder sound
  names with no real authored audio behind them** — it widens, rather than
  closes, the bark-audio asset gap already disclosed below.

### Security

These were found and fixed during Phase 2's own review passes before this
work was considered done, in the same spirit as Phase 1's four post-review
fixes:

- **Fixed a stale-entity-handle reuse in contraband search.** The client
  used to hold a raw entity handle across the full sniff-animation delay
  before resolving it to a network id — if the original target
  disconnected or was streamed out mid-animation, the recycled handle
  could end up resolving to the wrong player or vehicle. The network id is
  now captured immediately, before the animation starts.
- **Fixed trails vanishing outright at a water crossing instead of
  rendering up to the water's edge.** A redundant same-tick check in the
  trail-drawing loop set the "broken by water" flag before that same
  tick's draw pass ran, erasing the entire already-walked trail instantly
  rather than stopping cleanly at the crossing point as intended.
- **Added the missing radial menu entry point for tracking.** The
  scent/blood/gunpowder tracking functions had no in-game way to trigger
  or cancel a trail at all — nothing called them. Three context-sensitive
  radial items (start/cancel toggle per type) were added, each gated by
  its own feature flag. A follow-up bug in that same wiring was then found
  and fixed: switching to a different track type while already tracking
  silently canceled the active trail instead of switching to the new one,
  requiring a second click to actually start it. Clicking a different
  track type now correctly falls through to the proper "already tracking —
  stop first" notice instead of silently killing the wrong trail.
- **Fixed a watchdog-killing unclamped loop.** The trail marker-spacing
  draw loop advanced by a config-driven step with no lower-bound clamp; a
  misconfigured spacing value of zero or negative would have spun it
  forever with no yield. Not triggerable with the shipped default values,
  but now clamped to match an existing sibling loop's precedent.
- **Closed a door-scratch abuse vector (sustained broadcast spam).** A
  per-player cooldown alone didn't stop multiple separate certified
  accounts from independently hammering the *same* door, sustaining
  roughly 1,200 broadcasts/hour indefinitely with no cap. A second,
  door-keyed cooldown now has to pass alongside the per-player one before
  a scratch alert broadcasts, with its own periodic cleanup sweep since a
  door has no disconnect event to key cleanup off of.
- **Closed an entity-type spoofing gap in the same door-scratch handler.**
  A player standing near a real bystander could previously supply that
  bystander's own player or vehicle network id instead of a door's,
  triggering a server-wide alert anchored to the victim. The server now
  rejects anything that isn't actually an object before broadcasting,
  never trusting the client's own "is this door-shaped" check as the real
  gate.
- **Excluded a vehicle-tucked K9 from the door-scratch interaction.** A K9
  loaded into a K9 vehicle could still be offered the "Scratch to Alert"
  option, which made no sense in that state. Mirrors the existing
  vehicle-tuck exclusion already applied to the leash pull-back logic.
- **Closed a certification-revocation TOCTOU gap in contraband search.**
  `HasK9Access` was only checked once, at the moment a search request came
  in — but `server/search.lua`'s `ox_inventory` read can genuinely yield
  (an uncached vehicle trunk triggers a real lazy DB load), and a
  supervisor could revoke the searching officer's certification during
  that window. Without a second check, an already-decertified officer's
  in-flight search would still return its full result to them and could
  still trigger the contraband-alert broadcast to bystanders.
  `HasK9Access` is now re-checked immediately after that awaited read
  returns, before any result or broadcast is produced — rejected with a
  distinct `access_revoked` reason (logged to `k9_search_log` as
  `search_failed`, since a real inventory-read attempt did occur) rather
  than letting the in-flight search complete.
- **Corrected an invalid ped model in the K9 roster.** `Config.Peds`'
  Husky entry shipped as `a_c_huskie`, which is not a real GTA native ped
  model name — nobody could actually create or play a husky-modeled
  character under that spelling at all, so the roster entry was silently,
  completely non-functional rather than merely mis-labeled. The real
  native model is `a_c_husky`; `Config.Peds` now uses it.
- **Fixed the Phase 4 HUD's stamina reading being inverted.**
  `GetPlayerSprintStaminaRemaining` actually tracks sprint *exertion* —
  rising toward 100 as the player tires — despite its name, confirmed
  against multiple independent, widely-used community HUD resources.
  `client/hud.lua` now displays `100 - GetPlayerSprintStaminaRemaining(...)`
  so the stamina bar reads full-when-fresh and draining-when-tired, the
  way a stamina bar should.
- **Corrected an inaccurate native call shape in the water-crossing
  check.** `client/tracking.lua`'s water-detection helper called
  `GetWaterHeightNoWaves` with a trailing `0.0` argument as if the height
  were an input parameter; it's actually an extra Lua return value, and
  Lua silently discards an unused extra argument — so this was never a
  behavior bug, only a call shape that misdescribed the native. The call
  and its surrounding comment now match the real, community-confirmed
  `local found, waterHeight = GetWaterHeightNoWaves(x, y, z)` convention.

A second round of fixes landed after Phase 2's own review pass, as more
Phase 3/4 features shipped on this same branch:

- **Closed a real access-control gap in `Config.K9Inventory.accessScope`.**
  The previously-documented `'ownerOnly'` option was investigated against
  `ox_inventory`'s actual source and found to grant **no access control at
  all** — see the Added entry above and `server/inventory.lua`'s own header
  for the full trace. `accessScope` is now hard-enforced to `'department'`
  by a resource-start `assert`; any other value crashes the resource at
  startup by design, rather than being left selectable with a caveat
  comment.
- **Fixed a silent non-lethality bug in `NonLethalTakedown`'s NPC-target
  branch.** `SetEntityCanBeDamaged` is confirmed client-only; the
  server-side call this branch used to make was a no-op, so the
  damage-bracket meant to keep a takedown from killing an NPC target never
  actually applied. Fixed by relaying that native (and the equivalent
  bite-hold suppression natives, whose server-side validity could not be
  confirmed either way) to the requesting K9's own client instead — see the
  Known Limitations entry on Phase 3 below for the feature's remaining
  gaps.
- **Closed a stationary XP-farming gap in the newly-wired trail-arrival XP
  award.** Wiring `AwardXP` up to `trackSourceResolved` (see Added, above)
  introduced a fresh exploit of its own: a K9 already standing at, or who
  forges, a trail source's location could round-trip
  resolve→report-arrival for XP with no real travel. A new server-side
  distance gate (`server/tracking.lua`'s `MIN_TRACK_XP_DISTANCE`, 15m) now
  requires genuine movement between resolving a source and being credited
  for arriving at it; the cosmetic trail reveal itself is unaffected.
- **Reduced, but did not eliminate, a FearStress amplification vector.**
  `server/wellbeing.lua`'s gunfire-proximity input now dedupes by reporting
  source rather than counting raw relayed events, closing the primary way
  one spamming client could multiply a nearby K9's stress far past what one
  real, continuously-firing shooter would cause. See Known Limitations for
  the disclosed residual risk this does not close.

### Known Limitations

- **`Config.Features.ScentTracking` still ships `false` by default**, but
  is no longer a hard "can never functionally succeed" exception — its
  server-side source resolution (the `ox_inventory` `swapItems` hook
  described in the Added entry above) is now implemented. What remains is
  a verification gap, not a missing implementation: the hook's exact
  name/payload shape was confirmed this pass by direct source-reading
  (`ox_inventory`'s own `modules/inventory/server.lua`, corroborated two
  independent ways) rather than by an independent test against a live
  install, and the recommended one-time dev-time mitigation — logging
  `json.encode(payload)` once against your actual target-server
  `ox_inventory` version to confirm field names before relying on this in
  production — has **not** been performed as part of this pass. Do a
  one-time verification of that hook against your own `ox_inventory`
  install before enabling this flag in production; see
  `phase2_notes/scent_source_resolution.md` §2/§6 for the full confidence
  breakdown.
- Door interaction's nudge-open sub-feature is now implemented, but purely
  as a cosmetic push impulse/sound on the K9's own ped — it never reads or
  changes the door's actual lock state, and by design has no way to detect
  whether a given door is genuinely passable versus locked. It is not, and
  is not intended to be, an actual door-opening mechanic; treat it as
  flavor, not a functional unlock. `Config.DoorInteraction.nudgeRequiresUnlocked`
  remains hard-pinned to `true` via the resource-start assertion described
  above, since there is still no real lock-state check anywhere in this
  feature for that field to meaningfully gate.
- ~~The husky ped-model fix above was scoped to `Config.Peds` itself...~~
  **Resolved.** `client/movement.lua`'s Sit and Scratch-to-alert scenario
  lookup tables (`K9_SIT_SCENARIO_BY_MODEL_HASH` /
  `K9_DOOR_SCRATCH_SCENARIO_BY_MODEL_HASH`) both now key on the corrected
  `a_c_husky` spelling — a real husky K9 gets the intended
  Retriever-substitute sit/bark animation, not the default Shepherd
  fallback this bullet previously warned about.
- Phase 4's new vitality HUD (`Config.Features.HealthStaminaHUD`, still
  `false` by default) reads hunger/thirst from
  `QBX.PlayerData.metadata.hunger`/`.thirst` on the assumption those field
  names and a 0-100 scale match a live `qbx_core` install — this has
  **not** been independently verified against a real install this
  session (medium confidence per the design note it implements). Confirm
  against your own server's actual metadata schema before enabling this
  flag. Health and stamina are sourced from real client natives instead
  and are not affected by this caveat.
- Phase 3 (combat/action features) now has a **code-complete, registered**
  `BiteAndHold`/`NonLethalTakedown` implementation, but this is still not a
  usable, shipped feature. `PHASE3_SPEC.md`'s Revision 3 settled
  player-vs-player K9 combat as in-scope (reversing an earlier NPC-only
  default), and two cross-cutting design forks that were blocking
  implementation have both since been resolved as design decisions:
  - §12.0 item 8 (whether a non-cooperating player's client can be
    *prevented*, not merely detected, from ignoring a relayed combat
    effect) was resolved with five binding guardrails — in short, no
    server-authoritative consequence may ever depend on a relayed effect
    having actually landed on a target's client, and every player-facing
    string describing one is worded as best-effort, never as a guarantee.
  - §12.0 item 7 (which human officer is "this K9's handler" for Recall/
    `HandlerDownDefense` purposes, independent of momentary leash state)
    was resolved as a **design decision only** — a new, dedicated,
    DB-backed `k9_partnerships` registry, explicitly rejecting a reuse of
    the existing `LeashPairs` table. **The registry itself is still not
    implemented** — `server/partnership.lua` does not exist, only its
    `k9_partnerships` schema does (see Database above) — so
    `HandlerDownDefense` remains fully uncoded, `Config.Features.HandlerPartnership`
    does not exist in `config.lua`, and `PHASE3_SPEC.md`'s Recall mechanic
    (which likewise depends on knowing a K9's current handler independent
    of leash state) remains unimplemented for the same reason.
  - `AgilityAdvanced` is fully implemented behind its still-`false` flag
    (`client/movement.lua`) and does not depend on either fork above.
  - `BiteAndHold` and `NonLethalTakedown` are now **both fully implemented
    and registered** — a real change from the previous "inert, unreachable
    code" status. `server/combat.lua` (previously committed with no client
    half and deliberately excluded from `fxmanifest.lua`) now has a real
    `client/combat.lua` counterpart, and both files are wired into
    `fxmanifest.lua`'s script lists under item 8's guardrails. Writing the
    client half also found and fixed a genuine safety bug:
    `SetEntityCanBeDamaged` is confirmed **client-only** (no server-side
    `apiset` entry at all), so `NonLethalTakedown`'s NPC-target branch
    calling it server-side was a silent no-op — the damage-bracket meant to
    make an NPC takedown non-lethal never actually applied, so a
    "non-lethal" takedown against an NPC could genuinely kill it. Fixed by
    relaying that native (and the equivalent bite-hold suppression natives,
    whose server-side validity could not be confirmed either way) to the
    requesting K9's own client instead, which is already a trusted
    execution context for its own action.
  - **Despite that, the feature still cannot be triggered in a running
    game.** `client/combat.lua` exposes `RequestBiteHold()`,
    `ReleaseBiteHold()`, and `RequestTakedown()` as global functions, but
    **nothing calls them** — `client/radial.lua` was not extended with a
    "Bite & Hold" / "Takedown" item, and no other command or ox_target
    option exists either. A player cannot reach this feature through this
    resource's own UI even if both flags were flipped to `true`.
  - `PropDragging` is out of scope for `server/combat.lua` and remains
    fully uncoded.
  - `Config.Features.BiteAndHold`, `NonLethalTakedown`, and
    `HandlerDownDefense` must all stay `false`. `HandlerDownDefense` has no
    code to enable at all; `BiteAndHold`/`NonLethalTakedown` now have real,
    registered code, but no in-game entry point and no balance/anim-preview
    review pass yet — do not enable either.
- ~~**`Config.Features.XPProgression`'s `k9_progression` table is missing
  from `sql/install.sql`.**~~ **Resolved.** `sql/install.sql` now creates
  `k9_progression` (see Database above) — every previously-pcall-wrapped
  read/write in `server/progression.lua` now completes against a real
  table instead of silently failing, so XP actually persists across a
  disconnect/reconnect/restart. This never crashed the resource before
  (the pcall wrapping meant XP still worked correctly in-memory for the
  rest of a session), it just meant nothing was ever actually saved. All
  four of this resource's tables (`k9_certifications`, `k9_search_log`,
  `k9_partnerships`, `k9_progression`) are now present in the migration
  file; re-run `sql/install.sql` once against an existing database if it
  was already running without this table (`CREATE TABLE IF NOT EXISTS`
  makes that safe).
- **FearStress's gunfire-proximity input can still be sustained by a
  single forged reporter, even after this batch's dedup fix.**
  `qbx_k9unit:server:relayWeaponFire` (reused from Phase 2's gunpowder
  tracking) is payload-less and forgeable by design;
  `server/wellbeing.lua` now dedupes its gunfire log by reporting source
  before computing a nearby K9's stress rise, closing the primary
  amplification vector (one attacker's client spamming the event used to
  multiply stress far beyond what one real continuous shooter would
  cause). It does **not**, and structurally cannot without a real
  corroboration signal this payload-less event has no way to carry, stop a
  single determined attacker from indefinitely re-touching the event at
  its own ingest-cooldown rate to keep a nearby K9's FearStress/hesitation
  elevated — mechanically indistinguishable, server-side, from that same
  attacker genuinely firing continuously nearby the whole time. Inert
  today (nothing reads `IsHesitating()` yet, since `FearStressSystem` and
  the combat feature that would consume it both ship `false` and combat
  has no in-game entry point regardless); revisit if `server/combat.lua`'s
  `IsHesitating()` gate is ever enabled on a live server and abuse reports
  confirm this is a real problem in practice.
- **Bark-audio placeholder asset gap (widened, not closed, this batch).**
  This resource has never shipped a real bark audio asset — `'bark'`/
  `'qbx_k9unit_sounds'` have always been placeholder names with no `.ogg`/
  `.wav`/`.awc`/`.rel` file backing them anywhere in the tree. Advanced Bark
  Radial (`Config.Features.AdvancedBarkRadial`, above) adds three more
  placeholder sound names (`Bark_Alert`, `Bark_Aggressive`, `Bark_Calm`) on
  the same unbacked footing — more plumbing over the same gap, not a step
  toward closing it. `PlaySoundFromEntity` with an unrecognized name/set
  silently no-ops, so every bark action (basic or advanced) ships safely
  with no audio rather than erroring, but a server owner who enables either
  flag should not expect to hear anything until real audio assets are
  sourced and wired in. See `SPEC.md` §7 for the full asset-vs-native-only
  breakdown.
- **Every numeric value in this batch's new `Config.K9Inventory`,
  `Config.K9Medkit`, `Config.Wellbeing`, `Config.XP`, and
  `Config.DeployableKennel` tables is an unreviewed placeholder** — cooldowns,
  ranges, thresholds, XP award amounts, and the kennel's forward-offset/
  interact-distance values have not been through a config-validator or
  economy-balance pass, the same status this resource's existing Phase 2/4
  placeholder tables (`Config.ContrabandAlertTiers`,
  `Config.SearchContrabandItems`) already carry. Do not flip any of this
  batch's feature flags to `true` on a live server before that review
  happens.
- **`Config.DeployableKennel.propModel` (`'prop_doghouse_01'`) is a
  single-source, unconfirmed prop name** — found in an unrelated
  third-party resource's own config default, not independently
  cross-verified against a second source this pass. A confirmed-real
  fallback prop (`'prop_tennis_ball'`, thematically wrong but definitely
  real) is used automatically if the primary model fails to load client-side,
  so the feature degrades to "an oddly-shaped but real object appears"
  rather than failing silently — but confirm the primary model actually
  streams in-engine before treating it as settled.
- This batch has not yet had the same end-to-end release-readiness
  sign-off Phase 1 received; treat everything above as pending final
  packaging, not a shipped release.

## [0.1.0] - 2026-08-23

Initial Phase 1 release: a player-controlled K9 unit built on top of a
player's own persistent dog-model character, rather than a spawnable/
AI-controlled pet. This resource is purely an access-control and
interaction layer — it never spawns, despawns, or possesses a ped on
anyone's behalf.

### Added

- **Certification system** — qualifying officers (per `Config.Departments`
  grade thresholds) can certify or revoke a K9 handler via `/k9certify`,
  `/k9decertify`, and matching ox_target options on nearby players. A
  handler must be playing an eligible dog model (`Config.Peds`) to be
  certified, and certification is tracked per `(citizenid, job)` pair in
  a new `k9_certifications` table so history survives job changes and
  reconnects.
- **Offline revocation** — `/k9decertifyoffline [citizenid] [job]` lets a
  qualifying officer pull a certification from a handler who isn't
  currently connected.
- **Automatic revocation on leaving the department** — a handler's active
  certification is automatically revoked the moment they change jobs away
  from a K9-eligible department.
- **Consensual two-player leash system** — an officer can send a leash
  request to a nearby K9 handler (radial menu or ox_target); the handler
  must accept before anything attaches. Once attached, the K9's movement
  is elastically pulled back toward the officer as they separate, with an
  automatic hard-cap detach as a safety valve. Either party can detach at
  any time with zero consent required, so no one can be trapped leashed
  against their will.
- **"K9 Unit" radial menu** — a single radial entry point for Bark, Sit,
  Attach/Detach Leash, and Enter/Exit Vehicle, gated behind both the
  relevant `Config.Features` flag and a live server-side access check on
  every selection.
- **K9 vehicle load/release** — certified handlers can load their K9
  character into/out of configured K9 vehicle models (`Config.K9Vehicles`)
  via the radial menu or ox_target.
- **Bark relay** — a basic, cooldown-limited bark sound that a certified
  handler can trigger for nearby players to hear.
- **First/third-person K9 camera toggle** — a rebindable keybind (default
  `L`) that switches the game's built-in follow camera to first-person
  while playing a K9 character, using the native camera system's own
  per-model eye-height handling.
- SQL migration (`sql/install.sql`) for the `k9_certifications` table, and
  a `metadata.k9certified` read-only mirror written to the player's
  `qbx_core` metadata for client-side HUD display only (never used for
  server-side authorization).

### Fixed

These four issues were found and fixed during Phase 1's review passes,
after code review had already produced one "all clear" sign-off — they
are called out individually here because that earlier sign-off did not
catch them, and each was independently confirmed fixed before Phase 1 was
actually cleared to ship.

- **Fixed the K9 Unit radial menu being completely non-functional.**
  Every Phase 1 radial action (Bark, Sit, Attach/Detach Leash, Enter/Exit
  Vehicle) hard-errored the instant it was selected, because the menu's
  registration mixed a submenu-navigation item in with the action items
  in a single flat `lib.addRadialItem()` call with no matching
  `lib.registerRadial()` — ox_lib tried to navigate into a submenu that
  was never registered and threw before any action ever ran. The
  submenu is now registered properly via `lib.registerRadial`, with a
  single opener item on the root wheel linking into it.
  (`client/radial.lua`)
- **Fixed a leash-request spoofing and notification-spam gap.**
  Declining a leash request used to notify whatever server ID the client
  sent, without first checking that a real, matching pending request
  actually existed — letting a modified client spam arbitrary online
  players with fake "request declined" notifications, and silently
  swallow a genuine request meant for someone else in the process. The
  pending request is now validated before anything is sent or consumed.
  (`server/main.lua`, `respondLeashAttach`)
- **Added a missing rate limit on certification grant/revoke actions.**
  Granting, revoking, and offline-revoking a K9 certification — the most
  sensitive actions this resource exposes — had no per-officer rate
  limit, leaving room for a rapid grant/revoke toggle loop against a
  target. All three paths now share a per-granter cooldown.
  (`server/certifications.lua`)
- **Fixed the K9 first-person camera getting stuck on a resource
  restart.** Toggling the first-person K9 camera left the game's
  built-in follow-cam in first-person mode with nothing to reset it if
  the resource restarted mid-session. An `onResourceStop` handler now
  resets the camera to third-person, but only if this resource actually
  changed it, so an unrelated player camera preference is never
  clobbered. (`client/movement.lua`)

[0.1.0]: https://github.com/XxNightLordxX/FIvem/releases/tag/qbx_k9unit-v0.1.0
