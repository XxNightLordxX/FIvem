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
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'
