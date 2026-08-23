-- Root luacheck config for this repo.
--
-- Scope: currently only qbx_k9unit/ has Lua code, but this file is kept at
-- the repo root (not qbx_k9unit/.luacheckrc) per the "one shared root config
-- beats a different one per resource" rule, so a second resource dropped in
-- later inherits it automatically.
--
-- WHY THIS EXISTS ONLY AS A LINT CONFIG, NOT A FORMATTER: a stylua/format
-- config was deliberately rejected earlier for this codebase because of
-- genuine, intentional style choices a blanket formatter would rewrite away
-- (column-aligned tables, native-call argument grouping, the FiveM manifest
-- DSL). luacheck is pure lint -- it only reports, it never rewrites a single
-- byte -- so it does not carry that risk. What it DOES carry is false-positive
-- risk from not knowing FXServer/CFX natives or this resource's own
-- cross-file globals; the two blocks below exist specifically to eliminate
-- that, not to invent new rules.

std = "lua54" -- matches the actual runtime: .github/workflows/lua-check.yml
              -- already validates every file with luac5.4.

-- fxmanifest.lua is a declarative resource-manifest DSL (fx_version, game,
-- dependencies{}, shared_scripts{}, etc.), not procedural logic -- there is
-- no meaningful "unused variable" or "undefined global" bug class in it, only
-- an ever-growing set of DSL keywords (files, server_only, provide,
-- escrow_ignore, ...) that would need constant upkeep here for zero payoff.
-- Its syntax is already checked by the existing luac5.4 job. Excluded here
-- rather than allowlisted.
exclude_files = {
    "**/fxmanifest.lua",
}

-- Read-only: FiveM/CFX natives and the implicit server-event `source` global
-- this codebase actually calls. This list was generated FROM this
-- codebase's real usage (`luacheck qbx_k9unit` run with no config, then every
-- "accessing undefined variable" finding that is a genuine engine/runtime
-- global rather than a typo was pulled out) -- it is not a speculative
-- everything-native list, so it should stay in sync with actual usage: if a
-- newly-added file's `luacheck` run reports a NEW "accessing undefined
-- variable" for a real native, add it here rather than reaching for a
-- suppression comment.
read_globals = {
    -- Threading / events
    "CreateThread", "Wait", "AddEventHandler", "RegisterNetEvent",
    "TriggerClientEvent", "TriggerServerEvent", "RegisterCommand",
    "RegisterKeyMapping",
    -- Player / entity queries
    "GetPlayers", "GetActivePlayers", "GetPlayerFromServerId",
    "GetPlayerServerId", "GetPlayerName", "GetPlayerPed", "PlayerId",
    "PlayerPedId", "NetworkGetPlayerIndexFromPed",
    "GetCurrentResourceName",
    -- Entity / world
    "DoesEntityExist", "IsEntityDead", "GetEntityCoords", "SetEntityCoords",
    "GetEntityHeading", "SetEntityHeading", "GetEntityModel",
    "GetEntityType", "GetEntityArchetypeName", "GetOffsetFromEntityInWorldCoords",
    "SetEntityCollision", "SetEntityVisible", "FreezeEntityPosition",
    "AttachEntityToEntity", "DetachEntity", "GetGamePool",
    "GetHashKey", "GetWaterHeightNoWaves",
    "NetworkGetEntityFromNetworkId", "NetworkGetNetworkIdFromEntity",
    "NetworkDoesEntityExistWithNetworkId",
    "GetVehicleNumberPlateText", "IsPedInAnyVehicle",
    "GetEntityHealth", "GetEntityMaxHealth", "GetEntityForwardVector",
    "ApplyForceToEntity",
    -- Timers / misc client natives
    "GetGameTimer", "DrawMarker", "DisableControlAction",
    "ClearPedTasksImmediately", "TaskStartScenarioInPlace", "IsPedShooting",
    "PlaySoundFromEntity", "SetFollowPedCamViewMode",
    "GetPlayerSprintStaminaRemaining",
    -- NUI bridge (client/hud.lua)
    "SendNUIMessage", "RegisterNUICallback",
    -- Vision natives (see client/vision.lua -- these are the actual CFX
    -- native names, distinct from this resource's own IsNightVisionActive/
    -- IsThermalVisionActive wrapper functions declared below)
    "SetNightvision", "IsNightvisionActive", "SetSeethrough", "IsSeethroughActive",
    -- Server-side implicit global inside event handlers
    "source",
    -- ox_lib / oxmysql / export surface
    "lib", "exports", "MySQL",
    -- qbx_core's client-side player-data cache (client/hud.lua)
    "QBX",
}

-- Read+write: this resource's OWN cross-file globals. Every one of these is
-- deliberately declared as a bare global function (no `local`) in exactly
-- one file and called from others -- documented as this resource's
-- established "global helper, private per-file state" convention (see e.g.
-- server/cooldowns.lua's own file header, and server/certifications.lua for
-- the pattern it followed first). These are NOT undeclared-global typos, so
-- they belong in `globals` (readable AND assignable), not `read_globals`.
globals = {
    "Config",
    -- server/cooldowns.lua constructors
    "NewCooldown", "NewNestedCooldown", "NewMutex",
    -- server/certifications.lua
    "HasK9Access", "IsConfiguredK9Model", "RefreshCertificationCache",
    -- server/main.lua
    "ForceDetachLeashForSource", "ForceDetachOfficerLeashForSource",
    -- client/main.lua
    "IsOwnModelK9", "CanShowK9UI",
    -- client/movement.lua
    "ToggleK9Camera", "K9Sit", "IsLeashed", "RequestLeashAttach", "DetachLeash",
    -- client/tracking.lua
    "GetActiveTrackType", "StartScentTrack", "StartBloodTrack",
    "StartGunpowderTrack", "StopTracking", "IsTracking",
    -- client/vehicle.lua
    "EnterNearestK9Vehicle", "ExitK9Vehicle", "IsInK9Vehicle",
    -- client/vision.lua
    "IsThermalVisionActive", "IsNightVisionActive", "ToggleThermalVision",
    "ToggleNightVision",
}

-- Unused-argument checking is off. Rationale, not a blanket "quiet the
-- linter" call: this codebase's event/native callbacks (ox_target
-- interaction handlers, entity-enumeration callbacks, etc.) receive a fixed
-- positional signature (entity, distance, coords, name, ...) dictated by the
-- caller, not by this code -- a handler that only needs `entity` still has
-- to accept the rest positionally. Flagging every one of those as "unused
-- argument" is exactly the kind of pure noise this task asked to avoid, and
-- was confirmed by spot-checking: every current instance is a fixed-shape
-- callback parameter, not a leftover/forgotten one.
-- Unused LOCAL variables are still flagged (unused_args only silences
-- parameters) -- that class is left on because it does catch real mistakes.
unused_args = false

-- Line length is left unenforced. This codebase's dominant convention (see
-- any file's header comment, or e.g. server/cooldowns.lua) is dense, precise
-- inline documentation of WHY a line of code is the way it is, and several
-- existing lines already run well past a conventional 120-column limit for
-- exactly that reason. That is the same kind of deliberate, load-bearing
-- style choice that ruled out an automatic formatter earlier -- enforcing a
-- column limit here would flag the convention itself, not a real problem.
-- If this repo later wants line-length enforcement, that's a judgment call
-- for whoever owns the style guide, not something to slip in silently here.
max_line_length = false
