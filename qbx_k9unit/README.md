# qbx_k9unit

Player-controlled K9 unit for Qbox police/security departments — the K9 is
a player's own persistent character (see `SPEC.md` §1), not an NPC spawned
by a "handler." Certification-gated access, config-driven feature toggles.

**Status:** Phase 1 scaffold (manifest, config, folder layout, stub files
with contract comments). No feature logic is implemented yet — see the
`-- TODO(coder-backend): ...` / `-- TODO(coder-frontend): ...` markers
throughout `server/*.lua` and `client/*.lua`. This README is intentionally
short; a docs-agent pass will expand it once Phase 1 lands.

## Dependencies

Must be installed and started **before** `qbx_k9unit`:

- [`qbx_core`](https://github.com/Qbox-project/qbx_core)
- [`ox_lib`](https://github.com/overextended/ox_lib)
- [`ox_target`](https://github.com/overextended/ox_target)
- [`oxmysql`](https://github.com/overextended/oxmysql)

## Installation

1. Place this resource in your server's resources folder.
2. **Run the SQL migration:** `qbx_k9unit/sql/install.sql` (produced and
   reviewed by db-schema — see `SPEC.md` §4.3) creates the
   `k9_certifications` table. This scaffold's working assumption (flagged,
   not confirmed as fact — see `server/main.lua`'s header comment) is that
   oxmysql does **not** auto-execute `.sql` files dropped into a resource's
   own folder; import it manually via your usual DB client (phpMyAdmin,
   HeidiSQL, `mysql` CLI, etc.) before first start, same convention as
   most qb-core-lineage resources.
3. Add `ensure qbx_k9unit` to your `server.cfg`, after the dependencies
   above.
4. Review `config.lua` — in particular `Config.Departments` (job names +
   certifier grade thresholds) and `Config.Peds` (recognized K9 models) —
   and adjust to match your server's actual job names before going live.
5. A player becomes a usable K9 handler by: creating their character as a
   model listed in `Config.Peds`, getting hired into a job listed in
   `Config.Departments` through your server's normal hiring flow (outside
   this resource's scope), and then being certified by a qualifying
   officer via `/k9certify [id]` or the in-game ox_target option (see
   `SPEC.md` §4).

## Where things live

- `fxmanifest.lua`, `config.lua` — manifest and config, at the resource root.
- `server/certifications.lua` — the certification/permission system (hard
  requirement 2): grant/revoke/check, the in-memory cache, and automatic
  revocation on leaving the department.
- `server/main.lua` — bark relay, the leash consent/state handshake, and
  the intended home for future small access-gated actions that aren't
  part of the certification system itself.
- `client/main.lua` — K9-model self-check (display only) and the
  server-backed access check every other client file gates on.
- `client/movement.lua` — camera toggle, Sit emote, and the full leash
  subsystem (consent-based attach, elastic movement restriction, detach).
- `client/radial.lua` — the ox_lib "K9 Unit" radial menu (UI wiring only).
- `client/vehicle.lua` — K9 vehicle entry/exit.
- `sql/install.sql` — DB migration (owned by db-schema, not this pass).

See `SPEC.md` for the full product spec, phased build plan, and open
questions still needing sign-off.
