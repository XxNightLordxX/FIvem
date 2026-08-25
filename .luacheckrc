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
    "TriggerClientEvent", "TriggerServerEvent", "TriggerEvent", "RegisterCommand",
    -- Cancellable-wait primitives, needed by any thread that must abort a long
    -- sleep early instead of polling on a short Wait (client/combat.lua's
    -- suppression thread is the first such consumer). These are NOT natives and
    -- so have no ext/native-decls entry -- the 404 there means nothing for them.
    -- VERIFIED against primary source instead, in the Lua runtime itself:
    --   data/shared/citizen/scripting/lua/deferred.lua sets `_G.promise = M`
    --   data/shared/citizen/scripting/lua/scheduler.lua:114 sets
    --     `SetTimeout = Citizen.SetTimeout`
    -- and code/components/citizen-scripting-lua/src/LuaScriptRuntime.cpp loads
    -- BOTH files unconditionally via LoadSystemFile at runtime init. That
    -- component is the shared Lua runtime, so both globals exist on client and
    -- server alike -- no per-side qualification needed.
    "promise", "SetTimeout",
    -- GetConvarInt: server/bonetool.lua reads the second, explicit opt-in
    --   convar that must be set on top of Config.Features.BoneSweepDevTool
    --   before the dev-only /k9bonetool command will register at all.
    -- NetworkGetEntityOwner: server/propattachment.lua verifies which client
    --   actually owns a networked entity, so a client-supplied netId cannot
    --   be pointed at another player's real object.
    -- Both VERIFIED server-callable on 2026-08-25, not assumed: fetching
    -- citizenfx/fivem ext/native-decls/<Name>.md returns HTTP 200 with
    -- `ns: CFX` and `apiset: shared` for each. This matters because FXServer
    -- does NOT throw on an unregistered native -- the result buffer is never
    -- written, so the call returns zero/nil forever with nothing logged. Six
    -- such silent no-ops have already been found in this resource, including
    -- four death-check gates that had never once fired. Never allowlist a
    -- native here on an assumption; run the check.
    "GetConvarInt", "NetworkGetEntityOwner",
    -- client/tablet.lua's NUI focus handling. Both verified 2026-08-25
    -- rather than assumed, by two different routes because they answer
    -- differently:
    --   SetNuiFocus -- ext/native-decls/SetNuiFocus.md returns HTTP 200,
    --     ns: CFX, apiset: client. Directly confirmed.
    --   IsDisabledControlJustPressed -- its decl page 404s, which for a
    --     legacy R* native means "no CFX decl page was ever written", NOT
    --     "does not exist". Confirmed instead against the official
    --     natives.json: IS_DISABLED_CONTROL_JUST_PRESSED, hash
    --     0x91AEF906BCA88877. Several equally ubiquitous legacy natives
    --     already in this list (IsEntityAttached, IsEntityOnFire) 404 the
    --     same way, so a 404 alone is never grounds to reject a native --
    --     nor grounds to accept one. Check the hash database.
    -- Both are client-only, which is correct: NUI focus and control state
    -- have no server-side meaning.
    "SetNuiFocus", "IsDisabledControlJustPressed",
    --   SetPlayerModel -- ext/native-decls/SetPlayerModel.md returns HTTP
    --   404, which as the note above establishes is NOT proof of absence:
    --   the legacy R* natives largely have no decl page. Verified instead
    --   against the natives.json hash database (runtime.fivem.net/doc/
    --   natives.json, fetched 2026-08-25): namespace PLAYER, hash
    --   0x00A1CADD00108836, name SET_PLAYER_MODEL, params (player, model),
    --   and NO `apiset` key -- which for that database means the default,
    --   client-only. Its one call site, client/appearance.lua:202, is
    --   client-side, so the realm is right. This is the native that makes
    --   "assign a K9 ped role to any player, any model" actually change
    --   what the player looks like; get the realm wrong and it is a silent
    --   no-op with nothing logged, which is exactly this project's most
    --   expensive recurring bug class.
    "SetPlayerModel",
    --   CreatePed -- client/sarcalls.lua, for the cosmetic "you found them"
    --   reveal, drawn on the finder's own screen after the call has already
    --   resolved server-side. Verified the same way SetPlayerModel above
    --   was: its decl page 404s (a legacy R* native with no CFX page, which
    --   is never grounds to reject a native on its own), so checked against
    --   the natives.json hash database instead (fetched 2026-08-25):
    --   namespace PED, hash 0xD49F9B0955C367DE, name CREATE_PED, and NO
    --   `apiset` key -- which in that database means the default,
    --   client-only. client/sarcalls.lua is the only call site and is a
    --   client file, so the realm is right. The server half deliberately
    --   never creates a ped at all: the hidden target is a coordinate, not
    --   an entity, which is why nothing here can leak one.
    "CreatePed",
    -- vector3 is NOT a native and has no decl page to check -- it is a Lua
    -- RUNTIME TYPE that CitizenFX's Lua build adds to the language itself,
    -- alongside vector2/vector4/quat, in both realms. Nothing declares it,
    -- so luacheck cannot know about it; it is listed here for that reason
    -- and not because anything was assumed about a native. config.lua uses
    -- it for Config.K9EquipmentShop.locations, since ox_target's
    -- addSphereZone takes a vector3 for `coords`.
    "vector3", "vector2", "vector4", "quat",
    --   IsDuplicityVersion -- ext/native-decls/IsDuplicityVersion.md
    --   returns HTTP 200, apiset: shared, "Gets whether or not this is the
    --   CitizenFX server". shared/compat/core.lua uses it for realm
    --   detection, which is load-bearing: get it wrong and every adapter is
    --   built for the wrong VM and silently does nothing.
    "IsDuplicityVersion",
    -- ExecuteCommand -- verified 2026-08-25, HTTP 200, ns: CFX,
    -- apiset: shared. client/tablet.lua uses it to route a tablet action
    -- through the SAME RegisterCommand handler a player typing the command
    -- would hit, rather than reimplementing the action. That is deliberate:
    -- a forked entry point is how one path ends up guarded and the other
    -- does not, which this resource has already been bitten by once
    -- (ScratchAtDoor/NudgeDoor checked vehicle state in ox_target's
    -- canInteract but not inside the function). The tradeoff, documented at
    -- the call site, is that a command handler has no synchronous return
    -- value, so the tablet can only report "submitted", never "succeeded" --
    -- the command's own handler notifies the real outcome, exactly as it
    -- does for chat-typed usage.
    "ExecuteCommand",
    -- GET_RESOURCE_STATE. Used by server/tracking.lua's ox_inventory
    -- capability probe as the first gate, because accessing an export on a
    -- resource that is not started can throw rather than return nil.
    -- VERIFIED: ext/native-decls/GetResourceState.md declares apiset `shared`.
    "GetResourceState",
    -- Server-side entity pool enumeration, used by server/wellbeing.lua's rest-
    -- source proximity check. VERIFIED against primary source: each has an
    -- ext/native-decls entry declaring `apiset: server`. Same test the native
    -- audit established, and the same one that falsified the earlier
    -- "no apiset in frontmatter means client-only" method.
    "GetAllObjects", "GetAllVehicles",
    -- client/bonetool.lua's on-screen bone-index label (dev tool only).
    -- All VERIFIED present in citizenfx/natives at the namespaces named:
    -- PED/GetPedBoneIndex, HUD/SetText*, HUD/*TextCommandDisplayText,
    -- HUD/AddTextComponentSubstringPlayerName, GRAPHICS/SetDrawOrigin,
    -- GRAPHICS/ClearDrawOrigin. Client-side only, and only called from a
    -- client file. GetPedBoneIndex is used ONLY as a lookup shortcut in the
    -- sweep tool, never as a live conversion in the shipped feature -- its own
    -- doc page has an empty Return value section, so its not-found convention
    -- is unconfirmed and the tool reports raw values unfiltered rather than
    -- guessing which are hits.
    "GetPedBoneIndex",
    "SetTextScale", "SetTextFont", "SetTextColour", "SetTextCentre",
    "BeginTextCommandDisplayText", "AddTextComponentSubstringPlayerName",
    "SetDrawOrigin", "EndTextCommandDisplayText", "ClearDrawOrigin",
    -- Timecycle modifiers, client/screenfx.lua. VERIFIED client-only against
    -- primary source: both are declared in citizenfx/natives GRAPHICS with no
    -- ext/native-decls server override, and FXServer has no renderer at all.
    -- Hashes 0x2C933ABF17A1DF41 / 0x0F07E7745A236711.
    "SetTimecycleModifier", "ClearTimecycleModifier",
    -- GET_WORLD_POSITION_OF_ENTITY_BONE, client/propattachment.lua and
    -- client/bonetool.lua. VERIFIED: declared in citizenfx/natives ENTITY
    -- (the ENTITY namespace, not PED -- it takes a generic Entity, which is
    -- what makes it usable against a quadruped K9 ped), no ext/native-decls
    -- server override, so client-only. Takes a bone INDEX, not a name; a
    -- human-derived index is not meaningful on a dog skeleton, which is
    -- exactly what the bonetool sweep exists to resolve.
    "GetWorldPositionOfEntityBone",
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
    -- K9Medkit (client/medkit.lua, server/medkit.lua, Phase 4,
    -- PHASE4_SPEC.md §13.4.4) -- health-restore write native, the one
    -- ENTITY-STATE native this resource calls that wasn't already covered
    -- by the GetEntityHealth/GetEntityMaxHealth reads above
    "SetEntityHealth",
    -- K9 move-rate composer (client/movement.lua RecomputeK9MoveRate(),
    -- Phase 4, PHASE4_SPEC.md §13.0 Decision 2) -- the ONE call site for
    -- this native anywhere in this resource (see that function's own
    -- header comment for the "one and only call" confirmation and this
    -- native's honest confidence grading).
    "SetPedMoveRateOverride",
    -- Timers / misc client natives
    "GetGameTimer", "DrawMarker", "DisableControlAction",
    "ClearPedTasksImmediately", "TaskStartScenarioInPlace", "IsPedShooting",
    "PlaySoundFromEntity", "SetFollowPedCamViewMode",
    "GetPlayerSprintStaminaRemaining",
    -- AgilityAdvanced capsule-sweep vault (client/agility.lua, extracted from
    -- client/movement.lua, Phase 3,
    -- PHASE3_SPEC.md §12.5.5/§12.0 item 3) -- confirmed real natives per
    -- phase2_notes/phase3_combat_natives.md §5
    "StartShapeTestCapsule", "GetShapeTestResult", "SetEntityVelocity",
    -- NUI bridge (client/hud.lua)
    "SendNUIMessage", "RegisterNUICallback",
    -- Vision natives (see client/vision.lua -- these are the actual CFX
    -- native names, distinct from this resource's own IsNightVisionActive/
    -- IsThermalVisionActive wrapper functions declared below)
    "SetNightvision", "IsNightvisionActive", "SetSeethrough", "IsSeethroughActive",
    -- DeployableKennel (client/kennel.lua, server/kennel.lua, Phase 5 R&D,
    -- phase2_notes/phase5_features_research.md §5) -- object creation/
    -- placement/model-loading natives, none previously used anywhere else
    -- in this resource
    "CreateObject", "PlaceObjectOnGroundProperly", "DeleteEntity",
    "RequestModel", "HasModelLoaded", "SetModelAsNoLongerNeeded", "IsModelValid",
    -- Phase 3 BiteAndHold/NonLethalTakedown (client/combat.lua) --
    -- CLIENT-side ped-behavior/physics natives, each with a genuine,
    -- confirmed CLIENT call site in that file (applyBiteHold/forceRagdoll/
    -- applyNpcBiteHold/applyNpcTakedown and their own teardown handlers).
    -- Deliberately NOT added on the strength of server/combat.lua's own
    -- usage -- this session's native-api-assistant verification pass
    -- confirmed SetEntityCanBeDamaged is CLIENT-ONLY (no apiset entry on
    -- the canonical citizenfx/fivem native declaration) and could NOT
    -- confirm SetPedFleeAttributes/SetBlockingOfNonTemporaryEvents/
    -- SetPedToRagdollWithFall's SERVER-side validity either way (their
    -- CLIENT-side validity was never in question -- these are standard,
    -- well-established client ped-AI/physics natives). server/combat.lua
    -- no longer calls any of these four directly as of this same pass --
    -- every NPC-target effect is relayed to the requesting K9's own client
    -- instead (see that file's own header "NPC-TARGET NATIVE EXECUTION
    -- CONTEXT" section for the full finding and the reasoning for why this
    -- sidesteps the three unresolved natives' server-side status rather
    -- than assert it). Adding these here asserts ONLY their confirmed
    -- CLIENT validity, never their server-side status.
    "SetEntityCanBeDamaged", "SetPedFleeAttributes",
    "SetBlockingOfNonTemporaryEvents", "SetPedToRagdollWithFall",
    -- Phase 3 combat NON-COMPLIANCE DETECTION staff alert
    -- (server/combat.lua's FlagNonCompliance) -- standard, ubiquitous
    -- FXServer permission-check native (ACE permissions are inherently a
    -- server-side concept); HIGH confidence, not independently
    -- cross-checked against two live sources this session but not one of
    -- the four natives this pass's native-api-assistant verification
    -- flagged as genuinely in question -- see that same header section.
    "IsPlayerAceAllowed",
    -- Phase 3 PropDragging (client/combat.lua, server/combat.lua,
    -- PHASE3_SPEC.md §12.5.4). NetworkRequestControlOfEntity is called
    -- before every native this client applies to a ped it may not own --
    -- added after a QA pass found the pre-existing applyNpcBiteHold/
    -- applyNpcTakedown handlers omitted it, which this resource's own
    -- phase2_notes/phase3_combat_natives.md names as required for exactly
    -- those natives. It is best-effort: no success-check native is
    -- confirmed available here, so the call improves the odds of the
    -- effect landing rather than guaranteeing it -- see client/combat.lua's
    -- own disclosure. IsPedDeadOrDying/IsPedRagdoll back the NPC branch of
    -- server/combat.lua's IsTargetDowned (the player branch deliberately
    -- avoids them, per PHASE3_SPEC.md §12.0 item 6's finding that they
    -- measure raw physics state rather than a server's scripted laststand).
    "NetworkRequestControlOfEntity", "IsPedDeadOrDying", "IsPedRagdoll",
    -- Server-side implicit global inside event handlers
    "source",
    -- ox_lib / oxmysql / export surface
    "lib", "locale", "exports", "MySQL",
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
    -- client/audio.lua -- NUI audio bridge (Phase 5). Plumbing only; no
    -- audio files ship with this resource, see html/sounds/CREDITS.md.
    "PlayK9Sound", "StopK9Sound", "IsK9SoundActive",
    -- Accessor so client/proximityaudio.lua can read client/audio.lua's
    -- AUDIO_MAX_DISTANCE at runtime instead of hand-copying it. Those two
    -- constants MUST agree: a trigger distance above the gain-falloff
    -- ceiling means every ambient loop plays at gain 0.0 -- a live audio
    -- source and a poll thread producing nothing audible, with no error.
    -- proximityaudio.lua currently clamps against a local duplicate of the
    -- ceiling, which defends the likely direction (trigger distance raised)
    -- but not the reverse (ceiling lowered). This entry exists so that
    -- duplicate can be replaced by a live read.
    "GetK9AudioMaxDistance",
    -- server/combat.lua -- termination primitive with no gate of its own,
    -- exposed for server/recall.lua. Authorization is the CALLER's job;
    -- gating a termination path is how an unbounded trap gets built.
    "EndActiveEffectForHolder",
    -- client/recall.lua -- the handler's escape hatch.
    "RequestRecall",
    -- server/entities.lua -- the shared cross-feature netId claim registry.
    -- ResolveNetworkEntity deliberately performs NO ownership or proximity
    -- check (see its own doc comment), so every caller must add one. The
    -- problem that forced a SHARED registry: DeployableKennel, FetchMechanic
    -- and PropAttachments all spawn networked props and all fall back to the
    -- same model, but each feature's ownership check only ever scanned its
    -- OWN table -- so a netId naming another feature's live object read as
    -- "unclaimed, safe to delete". Three per-feature checks that must be kept
    -- in sync are three checks that will drift; one registry all three
    -- consult cannot. Consumed by server/kennel.lua, server/fetch.lua and
    -- server/propattachment.lua.
    -- NOTE for anyone touching these: a Release path must NEVER be gated on
    -- an access check. Termination and cleanup have to stay reachable even
    -- for a caller who has lost access, or the fix becomes a permanent
    -- stranded-entity trap -- a worse bug than the hijack it closed.
    "ClaimNetworkEntity", "ReleaseNetworkEntity", "IsNetworkEntityClaimedByOther",
    -- server/progression.lua -- validates a Config-supplied XP mint budget
    -- parameter. Exists because a boundary value must never silently mean
    -- "blocked forever": server/cooldowns.lua's IsOnCooldown already treats a
    -- non-positive threshold as PERMANENTLY ON rather than "no cooldown", and
    -- the budget's first implementation created each citizenid's bucket empty
    -- and checked it in the same call, silently dropping the first XP award
    -- of every session for every player.
    "IsValidXpMintBudgetParam",
    -- server/progression.lua -- an XP TIER UNLOCK. Tiers used to apply only
    -- multipliers; this is one of the first that returns real capability.
    -- Anything gated behind a tier is gated behind roughly 2h27m of
    -- deliberate grinding at the current capped ceiling, so only put things
    -- here that are harmless in the hands of someone who simply ground for
    -- them -- and never something that would override a high-command block,
    -- which resolves separately and must win.
    "GetXPTierMedkitCooldownMs",
    -- server/highcommand.lua -- the PD high-command tier. IsHighCommand is
    -- consulted by server/admin.lua, server/certifications.lua and
    -- server/bonetool.lua to let high command bypass their own rank gates;
    -- every consumer guards it with type(fn) == 'function' so those files
    -- still work with Config.Features.HighCommand off. AwardXPDirect is the
    -- /k9givexp entry point, deliberately SEPARATE from server/progression's
    -- AwardXP: that one takes a config-owned actionKey precisely so no caller
    -- can name an arbitrary amount, and weakening it would have removed the
    -- guarantee for every other caller. This one accepts an amount, and is
    -- why it is bounded by Config.HighCommand.maxXpPerGrant and audited on
    -- every use.
    "IsHighCommand", "AwardXPDirect",
    -- client/tablet.lua -- the K9 command tablet. OpenTablet/CloseTablet are
    -- exposed so the radial and any other entry point route through the SAME
    -- open/close path rather than each managing NUI focus themselves. That
    -- matters more here than the usual DRY argument: this is the first
    -- focus-taking surface in this resource, and a stuck NUI focus locks a
    -- player out of their own character with no recovery short of a
    -- reconnect. One close path, reachable from everywhere, is the whole
    -- defence -- so never call SetNuiFocus directly from a second site.
    "OpenTablet", "CloseTablet",
    -- client/radial.lua -- candidate resolution for the leash and partner
    -- actions. Both were `local` until 2026-08-25; client/tablet.lua called
    -- them as globals, which would have been a nil call at runtime, so the
    -- tablet's leash and partner buttons would simply have errored. The seam
    -- was opened rather than letting the tablet carry its own copy: two
    -- implementations of "who is standing near me and eligible" drift apart
    -- the first time either is fixed. Callers guard with
    -- type(fn) == 'function' because client/radial.lua returns early when
    -- its own feature flag is off, in which case neither is ever defined.
    "FindNearestLeashCandidate", "FindNearestPartnerCandidate",
    -- server/permissions.lua -- the grantable-permission layer. High command
    -- grants a named capability, or a per-person feature grant or block, to
    -- one specific handler or K9.
    -- HasPermission is the hot path, consulted by server/certifications.lua
    -- and others behind the usual type(fn) == 'function' guard so those
    -- files still work with Config.Features.PermissionGrants off.
    -- Two properties worth remembering before touching any of these:
    --   * a grant only ever WIDENS access. Resolution is grant, then high
    --     command, then the legacy rank gate, then deny -- so revoking a
    --     grant from someone who also qualifies by RANK does not remove
    --     their access, and the caller has to be able to tell the operator
    --     that rather than reporting a successful revoke.
    --   * revoke deactivates a row, never deletes one. This is an
    --     authorization audit trail: who gave whom what power, and when it
    --     was taken away.
    "HasPermission", "GrantPermission", "RevokePermission",
    "ListActivePermissionsForCitizenId", "ListPermissionRoster",
    -- Seams opened so other files can reach logic that was previously locked
    -- inside an ox_target closure or a `local`. Each verified defined before
    -- being declared here: client/inventory.lua:195, client/medkit.lua:181,
    -- server/search.lua:397.
    -- GetContrabandAlertTier exposes the PURE tier calculation only -- it is a
    -- testability seam, and must never become a path that reaches inventory
    -- contents while skipping the access, proximity and cooldown checks the
    -- real search callback enforces.
    "RequestOpenOwnK9Inventory", "RequestTreatNearestK9", "GetContrabandAlertTier",
    -- client/propattachment.lua + client/fetch.lua (PropAttachments,
    -- FetchMechanic). Both features are REGISTERED in fxmanifest.lua and load
    -- on every server; their flags ship `false`. The note that stood here --
    -- "UNREGISTERED ... files that are in the tree but do not yet ship" -- was
    -- true when written and was overtaken by the registration pass.
    "AttachPropToOwnPed", "DetachAndDeleteProp", "RequestToggleK9PropAttachment",
    "IsFetchCarryEngaged", "ReleaseFetchBall", "RequestRecallFetchBall", "RequestThrowFetchBall",
    -- server/cooldowns.lua constructors
    "NewCooldown", "NewNestedCooldown", "NewMutex",
    -- server/notify.lua -- shared ox_lib notify wrapper, replacing 12
    -- hand-rolled copies. Two files deliberately keep a thin local wrapper
    -- over it to preserve their own distinct notification title.
    "NotifyPlayer",
    -- server/certifications.lua
    "HasK9Access", "IsConfiguredK9Model", "RefreshCertificationCache",
    -- server/certifications.lua READ-ONLY ACCESSORS (certification-depth
    -- pass). All five are reads, never writes: a tier lookup, a tier-ordinal
    -- comparison, a specialization check, and two DB-authoritative reads the
    -- tablet and the offline-player paths need. No natives are involved, so
    -- none of these needed the native-decl verification step this file
    -- applies to real natives further down -- they are this resource's own
    -- cross-file global convention, identical in shape to the line above.
    "GetCertificationTier", "MeetsTierRequirement", "HasSpecialization",
    "QueryCertificationRecord", "QueryActiveSpecializations",
    -- client/appearance.lua + server/appearance.lua -- the K9 ROLE/MODEL
    -- DECOUPLING pass. These exist to satisfy a hard owner requirement:
    -- "everything works with any ped". A player holding the K9 ROLE gets
    -- every feature regardless of what model they wear -- a custom streamed
    -- ped, a ped absent from Config.Peds entirely, or a plain human model.
    -- That is why the role question (IsK9Role/HasK9Role) is deliberately a
    -- DIFFERENT function from the model question (IsEntityModelK9/
    -- IsConfiguredK9Model), which still answers "is this entity dog-shaped"
    -- and is still the right call for animations, bone indices and prop
    -- offsets. Do not collapse the two back into one: they answer different
    -- questions and the model one must keep its old meaning.
    -- IsK9RoleForPlayer answers the OTHER-player form of the same question,
    -- which the ten client target predicates need and which neither
    -- IsK9Role (self, client) nor HasK9Role (self, server) could answer.
    -- Remember what a predicate is: a CONVENIENCE gate. A stale or forged
    -- client-side answer here may make a menu option appear; the server
    -- re-checks on the action, so it must never make the action succeed.
    "IsK9Role", "IsK9RoleForPlayer",
    -- client/pursuitsprint.lua (K9_IDEAS.md §5). Same "resource-global so
    -- the radial and a chat command can both reach it" convention as
    -- RequestRecall above.
    "RequestPursuitSprint",
    -- client/sarcalls.lua (K9_IDEAS.md §3). RequestAbandonSarCall is
    -- UNCONDITIONAL by design -- never gated on access or certification --
    -- because abandoning a call is a termination path, and gating one is
    -- how the unbounded trap this resource forbids gets built.
    "RequestStartSarCall", "RequestAbandonSarCall",
    -- shared/compat/core.lua -- the resource auto-detection registry.
    -- Assigned in core.lua, read by the five sibling adapter files and by
    -- any future consumer. Same "global helper, per-file private state"
    -- convention as Config/IsHighCommand/NotifyPlayer above.
    "K9Compat",
    "HasK9Role", "GetAssignedK9Model", "ApplyK9PedRole",
    "ApplyK9AppearanceOnGrant", "MaybeRevertK9Appearance",
    -- ForceRevertK9Appearance -- PENDING, and listed here deliberately
    -- rather than left to redden lint for everyone: server/tablet.lua
    -- already calls it (lines 250/967/971) so high command can strip
    -- someone's K9 ped and put them back to a human from the tablet, but
    -- server/appearance.lua has not defined it yet. The call site guards
    -- with `type(fn) == 'function'` and fails closed, so today it is a
    -- clean no-op rather than an error. REMOVE THIS ENTRY if the function
    -- is ever abandoned -- an allowlisted name that nothing defines is how
    -- a missing function stops being visible, which is the failure class
    -- this project keeps finding.
    "ForceRevertK9Appearance",
    -- server/main.lua
    "ForceDetachLeashForSource", "ForceDetachOfficerLeashForSource",
    -- client/main.lua
    "IsOwnModelK9", "CanShowK9UI", "DenyK9UIAccess", "PlaySoundOnNetworkEntity",
    -- server/entities.lua (REFACTOR_ROADMAP.md near-term item 2) AND,
    -- separately, client/main.lua's OWN client-side function of the same
    -- name -- two distinct Lua VMs (server vs. client), same name by
    -- design for readability (same concept, mirrored API), same
    -- "shared name is intentional, not a shared symbol" convention
    -- client/main.lua's own header already documents for
    -- HasK9Access(source) vs. client/main.lua's HasK9Access().
    "ResolveNetworkEntity",
    -- REFACTOR_ROADMAP.md Revision 5 items 2b and 3, extracted this pass.
    -- ResolveConnectedPlayerFromPed (server/entities.lua) replaced three
    -- verbatim hand-copies in server/search.lua, server/inventory.lua and
    -- server/combat.lua; ResolvePlayerServerIdFromPed and IsEntityModelK9
    -- (both client/main.lua) replaced the client-side equivalents in
    -- client/medkit.lua and client/wellbeing.lua. Note
    -- ResolveConnectedPlayerFromPed deliberately scans GetPlayers()/
    -- GetPlayerPed rather than using NetworkGetPlayerIndexFromPed — that
    -- native combo was never verified server-side, and the scan is
    -- strictly more conservative. Do not "clean it up" into the native.
    "ResolveConnectedPlayerFromPed", "ResolvePlayerServerIdFromPed",
    "IsEntityModelK9",
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
    -- client/kennel.lua (Phase 5 R&D, DeployableKennel)
    "RequestDeployKennel",
    -- server/wellbeing.lua (Phase 4, PHASE4_SPEC.md §13.1 sub-phase 4c/4d,
    -- the unified wellbeing subsystem). RestoreInjury is read (never
    -- written) by server/medkit.lua behind a `type(RestoreInjury) ==
    -- 'function'` existence check; that guard is kept even now that
    -- server/wellbeing.lua really defines it, per this resource's
    -- "runtime existence guard, not a load-order assumption" convention.
    -- IsHesitating/IsDistracted are the read-only accessors PHASE4_SPEC.md
    -- §13.5 names as the cross-cutting dependency Phase 3's
    -- server/combat.lua consumes.
    "RestoreInjury", "IsHesitating", "IsDistracted",
    -- server/wellbeing.lua -- pure config read, no per-citizenid state, so a
    -- companion stun/flashbang resource can check immunity before applying an
    -- effect. Same cross-file accessor contract as IsHesitating/IsDistracted.
    "IsFlashbangImmune",
    -- client/wellbeing.lua (Phase 4) -- the calm-down action a future
    -- radial entry calls rather than re-deriving its own validation.
    "RequestK9CalmDown",
    -- server/progression.lua (Phase 4, PHASE4_SPEC.md §13.4.1,
    -- XPProgression) -- real, implemented this pass. AwardXP/GetXPTier are
    -- read from server/tracking.lua (the only current call sites) behind a
    -- `type(AwardXP) == 'function'` / `type(GetXPTier) == 'function'`
    -- existence guard each (same soft-dependency convention as
    -- RestoreInjury above), even though server/progression.lua itself
    -- already exists as of this pass -- the guard is kept regardless, per
    -- this resource's own "runtime existence guard, not a load-order
    -- assumption" convention (see fxmanifest.lua's own comment on
    -- server/medkit.lua's ordering for the precedent this follows).
    "AwardXP", "GetXPTier", "GetXP",
    -- client/movement.lua's PHASE4_SPEC.md §13.0 Decision 2 "move-rate
    -- composer" -- REAL, IMPLEMENTED (coder-frontend pass, real-bug fix):
    -- a qa-tester finding caught client/wellbeing.lua unconditionally
    -- writing K9MoveRateModifiers.fatigue/.injury/.mood and calling
    -- RecomputeK9MoveRate() with NEITHER symbol defined anywhere in this
    -- codebase (this comment previously read "FORWARD-DECLARED ONLY --
    -- neither symbol exists," which was accurate at the time it was
    -- written but is now stale) -- a guaranteed hard error the instant any
    -- wellbeing feature flag flipped true, latent only because every such
    -- flag defaults to false in config.lua. Both symbols are now defined
    -- for real in client/movement.lua: K9MoveRateModifiers is a plain
    -- table of named multiplier contributions (fatigue/injury/mood/
    -- xpTier/dragging, each defaulting to 1.0), and RecomputeK9MoveRate()
    -- composes them multiplicatively, clamps to [0.1, 2.0], and makes the
    -- single real SetPedMoveRateOverride call for the K9's own ped -- see
    -- that function's own header comment in client/movement.lua for the
    -- full composition/clamp/interaction writeup. client/progression.lua
    -- still reads BOTH behind `if K9MoveRateModifiers then ... end` /
    -- `type(RecomputeK9MoveRate) == 'function'` existence guards even
    -- though they now really exist -- that's intentional, not stale
    -- itself: this resource's documented convention is a runtime
    -- existence guard, not a load-order assumption (see fxmanifest.lua's
    -- own comment on server/medkit.lua's ordering for the same precedent),
    -- so those guards are correct to keep regardless of load order.
    "K9MoveRateModifiers", "RecomputeK9MoveRate",
    -- client/progression.lua (Phase 4, PHASE4_SPEC.md §13.4.1) -- real,
    -- implemented this pass. Exposed for a future HUD/display need
    -- (PHASE4_SPEC.md §13.4.1's own "additive read, not a new
    -- authorization surface" framing), not currently consumed elsewhere in
    -- this resource.
    "GetCurrentXPTier",
    -- client/combat.lua (Phase 3 completion pass, BiteAndHold/
    -- NonLethalTakedown self-initiated triggers) -- for a future
    -- client/radial.lua "Bite & Hold"/"Takedown" entry to call, same
    -- "global helper, private per-file state" convention as
    -- RequestLeashAttach/DetachLeash above.
    "RequestBiteHold", "ReleaseBiteHold", "IsBiteHoldEngaged", "RequestTakedown",
    -- server/partnership.lua (Phase 3, HandlerPartnership registry,
    -- PHASE3_SPEC.md §12.0 item 7/§12.3). RefreshPartnershipCache mirrors
    -- server/certifications.lua's RefreshCertificationCache reuse hook
    -- (called from this file's own onResourceStart backfill loop, exposed
    -- globally for the same "documented reuse hook" reason). GetActivePartnerCitizenId/
    -- IsActivePartnerOf are read-only accessors intended for BiteAndHold's
    -- Recall actor and HandlerDownDefense's trigger, neither built yet --
    -- see that file's own "FUTURE CONSUMERS" header section. ForceBreakPartnershipForCitizenId
    -- is citizenid-keyed (not source-keyed, unlike leash's
    -- ForceDetachLeashForSource/ForceDetachOfficerLeashForSource above) --
    -- intended for server/certifications.lua's cert-revoke/department-change
    -- call sites, which do not actually call it yet (a disclosed gap, not
    -- fixed here -- see client/partnership.lua's own header for the
    -- finding).
    "RefreshPartnershipCache", "ForceBreakPartnershipForCitizenId",
    "GetActivePartnerCitizenId", "IsActivePartnerOf",
    -- client/partnership.lua (Phase 3, the client half of
    -- server/partnership.lua above) -- RequestPartnerUp/BreakPartnership
    -- mirror client/movement.lua's RequestLeashAttach/DetachLeash pair
    -- exactly (self-initiated trigger + zero-consent termination).
    -- IsPartnered/GetPartnerServerId are the read-only accessors
    -- fxmanifest.lua's own comment on that file names as its exposed
    -- surface for a future client/radial.lua entry, not yet wired up.
    "RequestPartnerUp", "BreakPartnership", "IsPartnered", "GetPartnerServerId",
    -- RefreshPartnershipStateFromServer yields on a server callback and
    -- re-syncs the local cache before returning fresh IsPartnered()/
    -- GetPartnerServerId() values. It exists because the local cache can
    -- under-report after a reconnect (nothing re-syncs an already-partnered
    -- client), and a naive IsPartnered()-driven radial toggle would then
    -- offer "Partner Up" to exactly the player who needs the exit. Kept in
    -- client/partnership.lua rather than called raw from client/radial.lua,
    -- so every partnership round trip stays owned by one file.
    "RefreshPartnershipStateFromServer",
    -- client/defense.lua (Phase 3 HandlerDownDefense, PHASE3_SPEC.md
    -- §12.5.3). Per §12.0 item 2 this is UI/auto-targeting convenience,
    -- not an AI takeover -- ConfirmHandlerDownDefense is the PLAYER's
    -- confirmation of a surfaced prompt, never an autonomous action.
    "ConfirmHandlerDownDefense", "HasFreshDefensePrompt",
    "GetDefenseSuggestedTargetNetId",
    -- client/combat.lua's PropDragging trigger surface (Phase 3,
    -- PHASE3_SPEC.md §12.5.4) -- same self-initiated-trigger plus
    -- zero-consent-release shape as RequestBiteHold/ReleaseBiteHold above.
    -- Not yet wired into client/radial.lua; exposed for that future entry.
    "RequestDrag", "ReleaseDrag", "IsDragEngaged",
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
