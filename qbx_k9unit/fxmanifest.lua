fx_version 'cerulean'
game 'gta5'

name 'qbx_k9unit'
description 'Player-controlled K9 unit for Qbox police/security departments (Phase 1 vertical slice)'
version '0.1.0'

-- ----------------------------------------------------------------------
-- Manifest convention note (coder-architect, Phase 1 scaffold):
-- Matched against real Qbox-project resources fetched at scaffold time
-- (qbx_ambulancejob, qbx_policejob, qbx_truckerjob, qbx_smallresources):
--   * `ox_lib 'locale'` + `'@ox_lib/init.lua'` in shared_scripts is the
--     standard way every one of those resources pulls in ox_lib.
--   * `'@qbx_core/modules/playerdata.lua'` (client) and
--     `'@qbx_core/modules/lib.lua'` (shared) are included in every fetched
--     qbx_* job/feature resource, not just qbx_core itself. playerdata.lua
--     exposes a live-updated global `QBX.PlayerData` client-side cache
--     (job/citizenid/etc.) so client stubs should read from that rather
--     than re-inventing a player-data cache.
--   * ox_target and oxmysql ship no equivalent `@resource/init.lua` to
--     require -- they're consumed purely through their exports/wrapper --
--     so they only need to appear in `dependencies` below (oxmysql also
--     gets its `@oxmysql/lib/MySQL.lua` wrapper in server_scripts since
--     server/certifications.lua and server/search.lua do direct SQL work
--     -- server/main.lua does not call MySQL.* at all, it only calls
--     RefreshCertificationCache/HasK9Access, exposed globals owned by
--     server/certifications.lua).
-- ----------------------------------------------------------------------
ox_lib 'locale'

dependencies {
    'qbx_core',
    'ox_lib',
    'ox_target',
    'oxmysql',
    'ox_inventory', -- Phase 2: server/search.lua reads item weights/contents via ox_inventory exports (GetInventoryItems/GetContainerFromSlot); Phase 1 never touched inventory.
}

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config.lua',
}

-- Phase 4: first NUI surface this resource has ever had (the passive
-- vitality HUD, Config.Features.HealthStaminaHUD — still `false` by
-- default in config.lua, see client/hud.lua). ui_page is loaded/kept
-- alive for the entire client session (not opened/closed like a modal —
-- html/index.html starts hidden and stays that way client-side until
-- client/hud.lua's poll thread says otherwise), per
-- phase2_notes/phase4_hud_bridge_design.md §7.
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
    'client/movement.lua',
    'client/radial.lua',
    'client/vehicle.lua',
    'client/tracking.lua', -- Phase 2
    'client/search.lua',   -- Phase 2
    'client/vision.lua',   -- Phase 2
    'client/hud.lua',      -- Phase 4
    'client/inventory.lua', -- Phase 4 (K9Inventory, PHASE4_SPEC.md §13.4.2)
    'client/kennel.lua',   -- Phase 5 R&D (DeployableKennel, phase2_notes/phase5_features_research.md §5)
    'client/medkit.lua',   -- Phase 4 (K9Medkit, PHASE4_SPEC.md §13.4.4)
    'client/wellbeing.lua', -- Phase 4 (unified Fatigue/Mood/FearStress/Distraction/Injury subsystem, PHASE4_SPEC.md §13.0 Decision 1)
    'client/progression.lua', -- Phase 4 (XPProgression, PHASE4_SPEC.md §13.4.1)
    'client/combat.lua', -- Phase 3 (BiteAndHold/NonLethalTakedown, PHASE3_SPEC.md §12.5.1/§12.5.2) -- the client half of server/combat.lua; no ordering dependency on anything else in this list (reads Config.Combat/Config.Features from config.lua, already loaded via shared_scripts, and calls CanShowK9UI/DenyK9UIAccess from client/main.lua, which is loaded earlier in this same list, but Lua global-function resolution here is at CALL time, not load time, so this would still work even loaded first)
    'client/partnership.lua', -- Phase 3 (HandlerPartnership registry, PHASE3_SPEC.md §12.0 item 7/§12.3) -- the client half of server/partnership.lua (Partner Up consent prompt, ox_target option, IsPartnered()/GetPartnerServerId(), and RefreshPartnershipStateFromServer() which yields on a server callback to re-sync the local cache before a caller decides Partner Up vs Break Partnership -- the local cache alone can under-report after a reconnect. The radial entry is now wired, in client/radial.lua). Same "no ordering dependency" note as client/combat.lua above -- calls CanShowK9UI()/IsOwnModelK9() from client/main.lua only at CALL time (inside RequestPartnerUp/the ox_target predicate), never at file-load time.
    'client/defense.lua', -- Phase 3 HandlerDownDefense client half -- soft dependency on client/combat.lua's IsBiteHoldEngaged via a runtime existence guard, so no hard load-order requirement
    'client/screenfx.lua', -- Phase 4 (ContrabandScreenFX). Held out of this manifest until its two timecycle natives were verified against primary source (no native is allowlisted here on an unverified assertion); both are now confirmed client-only. Registers its OWN handler for qbx_k9unit:client:applyContrabandScreenFx rather than extending client/search.lua -- an additional consumer, the same pattern server/wellbeing.lua and server/tracking.lua use for relayDamageEvent. No load-order dependency.
    'client/audio.lua', -- Phase 5 NUI audio bridge. PLUMBING ONLY -- no audio files ship with this resource (html/sounds/CREDITS.md records an egress-blocked sourcing attempt and four unverified CC0 leads). Every play against a not-yet-supplied html/sounds/<key>.ogg degrades to a silent no-op end to end. Has no caller yet: client/main.lua's PlaySoundOnNetworkEntity is deliberately still on the RAGE path, so this loads inert.
    'client/recall.lua', -- Phase 3 Recall (client half). Exposes RequestRecall() and the k9recall command. Deliberately does NOT call CanShowK9UI()/DenyK9UIAccess() -- Recall is a TERMINATION path and gating one is how the unbounded trap this resource forbids gets built.
    'client/exports.lua', -- Public client-side export surface. No load-order dependency: every wrapped function is reached through a `type(fn) == 'function'` guard plus pcall, so an export over a file that early-returns under its own feature flag returns a documented nil/false rather than erroring.
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- REFACTOR_ROADMAP.md item 1: shared cooldown/mutex helper (NewCooldown/
    -- NewNestedCooldown/NewMutex), loaded FIRST among this resource's own
    -- files since main.lua/certifications.lua/tracking.lua/search.lua all
    -- call these resource-global constructors at their own file-load time.
    'server/cooldowns.lua',
    -- REFACTOR_ROADMAP.md near-term item 2: shared defensive netId->entity
    -- resolver (ResolveNetworkEntity), loaded alongside cooldowns.lua and
    -- before main.lua/search.lua, its two consumers.
    'server/entities.lua',
    'server/main.lua',
    'server/certifications.lua',
    -- Phase 3 (HandlerPartnership registry, PHASE3_SPEC.md §12.0 item 7
    -- Revision 5/§12.3) -- loaded after server/cooldowns.lua (NewCooldown/
    -- NewMutex at this file's own file-load time) and server/certifications.lua
    -- (IsConfiguredK9Model/HasK9Access reuse at runtime inside the
    -- eligibility check below). Per this file's own header note: loaded
    -- AFTER certifications.lua even though certifications.lua's
    -- RevokeCertification/RevokeCertificationOffline/OnJobUpdate call INTO
    -- this file's ForceBreakPartnershipForCitizenId -- same "runtime
    -- existence guard, not a load-order assumption" convention as every
    -- other soft cross-file dependency in this manifest (see this file's
    -- own comment on server/medkit.lua's RestoreInjury reuse below); those
    -- three call sites guard the call with a `type(...) == 'function'`
    -- check rather than assuming load order, since by the time any of them
    -- can actually FIRE (a real player action), every server_scripts file
    -- below has already finished loading regardless of manifest order.
    'server/partnership.lua',
    -- Phase 3 HandlerDownDefense (PHASE3_SPEC.md §12.5.3) -- hard dependency on
    -- cooldowns.lua (NewCooldown at file-load time); reads partnership state via
    -- GetActivePartnerCitizenId, server-side only, never a client claim.
    'server/defense.lua',
    'server/tracking.lua', -- Phase 2
    'server/search.lua',   -- Phase 2
    'server/inventory.lua', -- Phase 4 (K9Inventory, PHASE4_SPEC.md §13.4.2)
    'server/kennel.lua',    -- Phase 5 R&D (DeployableKennel, phase2_notes/phase5_features_research.md §5) -- loaded after cooldowns.lua (NewCooldown at file-load time) and certifications.lua (HasK9Access)
    'server/medkit.lua',    -- Phase 4 (K9Medkit, PHASE4_SPEC.md §13.4.4) -- loaded after cooldowns.lua (NewCooldown/NewMutex at file-load time) and certifications.lua (IsConfiguredK9Model); no ordering dependency on server/wellbeing.lua since RestoreInjury is called through a runtime existence guard, not a load-order assumption
    -- Phase 4 (unified wellbeing subsystem, PHASE4_SPEC.md §13.0 Decision 1) --
    -- loaded after cooldowns.lua (NewCooldown at file-load time) and
    -- certifications.lua (HasK9Access). Deliberately loaded AFTER
    -- server/tracking.lua: both register a handler for the same
    -- relayDamageEvent/relayWeaponFire client events (FiveM fires every
    -- registered handler, so this is an additional CONSUMER of an existing
    -- signal, not a replacement -- PHASE4_SPEC.md §13.0's own "a new
    -- consumer, not a new detection mechanism" framing), and each keeps its
    -- own independent rate limit.
    'server/wellbeing.lua',
    -- Phase 4 (XPProgression, PHASE4_SPEC.md §13.4.1) -- loaded after
    -- tracking.lua/search.lua, which call AwardXP/GetXPTier through runtime
    -- existence guards rather than a load-order assumption.
    'server/progression.lua',
    -- Phase 3 (BiteAndHold/NonLethalTakedown, PHASE3_SPEC.md §12.5.1/
    -- §12.5.2/§12.0 item 8) -- loaded after cooldowns.lua (NewCooldown/
    -- NewMutex at file-load time, per this file's own header) and
    -- entities.lua/certifications.lua (ResolveNetworkEntity/HasK9Access,
    -- called at runtime, but kept load-ordered before this file for the
    -- same reason every other consumer of those two already is).
    -- Deliberately loaded AFTER server/wellbeing.lua/server/progression.lua
    -- even though it CONSUMES IsHesitating/IsDistracted (wellbeing.lua) and
    -- AwardXP (progression.lua) -- same "runtime existence guard, not a
    -- load-order assumption" convention every other soft cross-file
    -- dependency in this manifest already follows (see this file's own
    -- comment on server/medkit.lua's RestoreInjury above); loading after
    -- both simply means those guards are non-nil from this file's very
    -- first tick rather than only after a resource restart, not a
    -- correctness requirement.
    'server/combat.lua',
    -- Phase 3 Recall (server half) -- the handler's escape hatch, ending
    -- whatever active effect their partnered K9 holds. Loaded after
    -- cooldowns.lua (NewCooldown at file-load time -- a hard requirement);
    -- no ordering requirement against partnership.lua or combat.lua, both
    -- consumed through runtime existence guards.
    'server/recall.lua',
    -- Partnership-tenure milestone XP bonus (Config.Features.PartnershipTenureBonus,
    -- COMPLEMENTARY_FEATURES.md item 7) -- the first gameplay consequence
    -- wired to the HandlerPartnership registry, which landed as a
    -- foundation with none. Extends partnership.lua/progression.lua through
    -- their already-exposed accessors; no load-order dependency on either.
    -- REQUIRES k9_partnerships.tenure_bonus_tier_granted (sql/install.sql
    -- for fresh installs, sql/migrations/0003_*.sql for existing ones);
    -- without it the milestone would re-grant on every restart, so its
    -- queries are pcall-wrapped and go inert rather than misbehaving.
    'server/tenure.lua',
    -- Read-only, ACE-gated admin/audit surface over the three tables this
    -- resource writes. Loaded after cooldowns.lua (NewCooldown at file-load
    -- time); deliberately does NOT call into certifications.lua or
    -- partnership.lua -- see its own ACCESS MODEL header.
    'server/admin.lua',
    -- Public server-side export surface -- this resource's first exports.
    -- Self-registers via the runtime `exports('name', fn)` call, so no
    -- `server_exports` manifest key is needed. Loaded last so every wrapped
    -- internal function is already defined, though each call is guarded
    -- anyway.
    'server/exports.lua',
}

lua54 'yes'
-- OAL = "One Argument List", an experimental change to the Lua native-calling
-- convention -- NOT an object/asset loader, which is what a release review
-- initially assumed and flagged as risky to ship. Under it, natives no longer
-- auto-unpack a vector3 into x, y, z.
--
-- KEPT DELIBERATELY, after checking rather than assuming. qbx_core, ox_lib,
-- ox_target and ox_inventory all set this flag in their own live main-branch
-- manifests (verified Aug 2026), so a server running this resource already
-- needs a build supporting fxv2 OAL regardless of what we set here. Dropping
-- it would reduce this resource's real exposure by nothing.
--
-- This resource's own calls are already OAL-safe: every coordinate-taking
-- native is passed manually unpacked x/y/z, never a bare vector3. The one
-- GetShapeTestResult call (client/movement.lua's vault sweep) reads only
-- resultCode and hit -- never endCoords or surfaceNormal, the exact vector
-- returns reported broken by lua54 + fxv2_oal together on some builds.
-- If a future call here needs to read a shape-test or raycast vector result,
-- re-verify that known issue against the build in use FIRST.
use_experimental_fxv2_oal 'yes'
