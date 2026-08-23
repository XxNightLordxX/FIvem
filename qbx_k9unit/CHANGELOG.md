# Changelog

All notable changes to `qbx_k9unit` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

Phase 2 (tracking, contraband search, vision, door interaction) has landed
on this branch as a complete feature set with real client and server
implementations, but it has **not** been through the same release-readiness
pass Phase 1 got before shipping — there is no version bump yet, and Phase 3
(combat/action features) hasn't had any implementation start, only design
scoping. Everything below is pending final packaging.

### Added

- **Scent/blood/gunpowder tracking** — a certified handler can start a
  self-following trail for any of the three configured scent types from a
  new "K9 Unit" radial submenu entry per type (Track Scent / Track Blood /
  Track Gunpowder), each an independent start/cancel toggle gated by its
  own `Config.Features` flag. Trails render as ground markers with
  configurable spacing and decay across water crossings, cutting off
  cleanly at the water's edge rather than vanishing outright.
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
- **Door interaction (scratch-to-alert)** — a certified handler can scratch
  at a nearby door-like object via ox_target to broadcast an alert sound to
  everyone with that door streamed in. This is alert-only in this drop;
  nudge-open is not implemented.
- **Full Phase 2 config schema** — `Config.Tracking`, `Config.SearchZones`,
  `Config.SearchContrabandItems`, `Config.DoorInteraction`,
  `Config.Vision`, and related tuning tables, plus a `Config.Features`
  flag per Phase 2 feature so each can be enabled independently once ready.
  New `ox_inventory` dependency (required by contraband search).
- **Resource-start config safety check** — the resource now refuses to
  start if `Config.DoorInteraction.nudgeRequiresUnlocked` has been set to
  `false`. It's documented as a hard safety requirement (nudge-open must
  never be able to bypass a locked door), not a server-tunable option, so
  a bad value now fails loudly at startup instead of silently shipping a
  future lockpick-equivalent bypass once nudge-open is eventually built.

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

### Known Limitations

- **`Config.Features.ScentTracking` MUST remain `false` on a live server.**
  Scent tracking's server-side source resolution is not implemented —
  the server always reports "not found" for a scent trail's origin. The
  research half of this gap is now closed: a tech-scout pass confirmed a
  real, server-side `ox_inventory` hook
  (`exports.ox_inventory:registerHook('swapItems', ...)`) that fires on
  every item drop and resolves to a live, non-client-claimed position —
  see `phase2_notes/scent_source_resolution.md` and `SPEC.md` §9 item 17
  for the confirmed mechanism and the exact `server/tracking.lua` change
  it implies. The `.lua` implementation itself has **not** been written
  yet, so this remains an explicit, disclosed gap (not a hidden
  shortcut), and it still ships disabled by default. **Do not flip this
  flag to `true` until the `server/tracking.lua` implementation lands**
  — doing so will not deliver a working feature and the acceptance
  criteria for scent tracking are not currently met end-to-end.
- Door interaction ships as scratch-to-alert only; nudge-open (opening a
  locked door) is not implemented in this drop, and the config safety
  guard described above exists specifically to keep it safe to add later.
- Phase 3 (combat/action features) has design scoping only
  (`PHASE3_SPEC.md`) — no implementation has started.
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
