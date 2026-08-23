# Changelog

All notable changes to `qbx_k9unit` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
