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
--     server/certifications.lua and server/main.lua do direct SQL work).
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

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
    'client/movement.lua',
    'client/radial.lua',
    'client/vehicle.lua',
    'client/tracking.lua', -- Phase 2
    'client/search.lua',   -- Phase 2
    'client/vision.lua',   -- Phase 2
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/certifications.lua',
    'server/tracking.lua', -- Phase 2
    'server/search.lua',   -- Phase 2
}

lua54 'yes'
use_experimental_fxv2_oal 'yes'
