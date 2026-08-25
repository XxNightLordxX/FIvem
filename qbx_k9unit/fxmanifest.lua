fx_version 'cerulean'
game 'gta5'

name 'qbx_k9unit'
author 'John Allday'
description 'Player-controlled K9 unit for Qbox police/security departments'
version '0.1.0'

-- Built by John Allday. Proprietary -- not open source. See LICENSE.md for
-- the full terms; the short version is that this is licensed for use on the
-- purchaser's own server and may not be redistributed, resold, shared or
-- published, in whole or in part.

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
    -- NOTE for anyone setting Config.Database.enabled = false: oxmysql
    -- below is a HARD dependency and FXServer refuses to start this
    -- resource without that resource present and started. That check runs
    -- before config.lua is ever read, so no config setting can route
    -- around it. Turning Config.Database off means this resource sends
    -- oxmysql no queries and needs none of its own tables -- it does NOT
    -- mean you can uninstall oxmysql.
    'ox_inventory', -- Phase 2: server/search.lua reads item weights/contents via ox_inventory exports (GetInventoryItems/GetContainerFromSlot); Phase 1 never touched inventory.
}

shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config.lua',
    -- RESOURCE AUTO-DETECTION (Config.Compat). shared_scripts, not
    -- client_scripts/server_scripts, because every one of these files runs
    -- on BOTH Lua VMs from the same source: core.lua works out its own
    -- realm via IsDuplicityVersion() and hands 'client' or 'server' to each
    -- adapter's factory, so one registration serves both sides.
    -- HARD ORDER: core.lua before all five adapters -- they call
    -- K9Compat.RegisterAdapter at their own file-load time, so core being
    -- later is a nil-index at start, not a degraded feature. core.lua after
    -- config.lua, since it reads Config.Compat. Order AMONG the five
    -- adapters does not matter.
    'shared/compat/core.lua',
    -- 'shared/compat/inventory.lua', -- NOT YET WRITTEN. Commented out deliberately: a manifest entry for a file that does not exist is a resource-start error, which would take the WHOLE resource down, not just this adapter. Uncomment the moment the file lands.
    -- 'shared/compat/target.lua', -- NOT YET WRITTEN. Commented out deliberately: a manifest entry for a file that does not exist is a resource-start error, which would take the WHOLE resource down, not just this adapter. Uncomment the moment the file lands.
    -- 'shared/compat/framework.lua', -- NOT YET WRITTEN. Commented out deliberately: a manifest entry for a file that does not exist is a resource-start error, which would take the WHOLE resource down, not just this adapter. Uncomment the moment the file lands.
    -- 'shared/compat/dispatch.lua', -- NOT YET WRITTEN. Commented out deliberately: a manifest entry for a file that does not exist is a resource-start error, which would take the WHOLE resource down, not just this adapter. Uncomment the moment the file lands.
    -- 'shared/compat/ambulance.lua', -- NOT YET WRITTEN. Commented out deliberately: a manifest entry for a file that does not exist is a resource-start error, which would take the WHOLE resource down, not just this adapter. Uncomment the moment the file lands.
}

-- Phase 4: first NUI surface this resource has ever had (the passive
-- vitality HUD, Config.Features.HealthStaminaHUD — `true` in config.lua
-- as of 2026-08-25, when every Config.Features flag was enabled; see
-- client/hud.lua). ui_page is loaded/kept
-- alive for the entire client session (not opened/closed like a modal —
-- html/index.html starts hidden and stays that way client-side until
-- client/hud.lua's poll thread says otherwise), per
-- phase2_notes/RESEARCH_ARCHIVE.md#hud-bridge §7.
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    -- The NUI audio layer fetches 'sounds/<key>.ogg' relative to
    -- html/index.html, so every shipped sound needs its own entry here or it
    -- 404s on the client and the loader degrades to silence -- which looks
    -- exactly like the feature being off.
    -- COMPLETE as of 2026-08-25: all five keys the bridge can request now
    -- ship. Four come from client/audio.lua's SOUND_NAME_TO_FILE_KEY map;
    -- the fifth, growl_ambient, comes from Config.ProximityAudioFX.soundName
    -- via ToAudioFileKey's lowercase fallback, which is easy to miss when
    -- auditing this list against that map alone.
    -- Provenance and licences are recorded in html/sounds/CREDITS.md -- read
    -- it before adding or replacing any file here. The three extra barks are
    -- genuinely distinct takes from the same source recording as bark.ogg,
    -- not copies of it, and growl_ambient is a seam-verified loop (the
    -- proximity layer plays it with loop = true, so an edge fade would put an
    -- audible gap in every repeat).
    'html/sounds/bark.ogg',
    'html/sounds/bark_alert.ogg',
    'html/sounds/bark_aggressive.ogg',
    'html/sounds/bark_calm.ogg',
    'html/sounds/growl_ambient.ogg',
    -- K9 Command Tablet (Config.Features.CommandTablet). FiveM allows only
    -- ONE ui_page, which is already html/index.html for the vitality HUD, so
    -- the tablet lives in its own document loaded through an <iframe> that
    -- index.html embeds, with tablet-bridge.js relaying between the two
    -- windows. That keeps it fully isolated from the HUD's own DOM, CSS and
    -- JS -- html/app.js is not touched at all -- which matters because the
    -- HUD is a passive always-on surface and the tablet is an interactive
    -- one that takes NUI focus.
    -- EVERY ONE OF THESE FOUR MUST BE LISTED. An unlisted asset is a 404
    -- that the loader swallows, and a tablet that silently never renders
    -- looks exactly like the feature being switched off.
    'html/tablet.html',
    'html/tablet.js',
    'html/tablet.css',
    'html/tablet-bridge.js',
    -- ox_lib 'locale' has been declared at the top of this manifest since Phase
    -- 1, promising localisation that did not exist -- every player-facing
    -- string was hardcoded English until now. That migration is COMPLETE as of
    -- 2026-08-25: 319 keys, every player-facing string in the resource routed
    -- through locale(), cross-checked to zero missing and zero unused. The
    -- earlier note here said 2 of ~48 files were migrated; that is long stale.
    -- Listed explicitly rather than as 'locales/*.json': research into the
    -- files{} glob found `*` currently behaves recursively and is itself the
    -- subject of an open upstream replacement proposal, and every other entry
    -- in this manifest is explicit. Add each new locale file by name.
    'locales/en.json',
}

client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/main.lua',
    'client/appearance.lua', -- K9 role client half (IsK9Role/IsK9RoleForPlayer). Loaded after client/main.lua because CanShowK9UI() consults IsK9Role() -- resolution is at CALL time, so this is convention rather than a hard requirement, but keep the order.
    'client/movement.lua',
    'client/agility.lua', -- AgilityAdvanced (fence/window vault), extracted from client/movement.lua. Self-contained: no shared local state with its old home, and nothing else in the resource read its locals. No load-order dependency -- calls CanShowK9UI()/IsOwnModelK9() at call time only.
    'client/radial.lua',
    -- K9 command tablet (Config.Features.CommandTablet). Two surfaces in
    -- one: high command gets a control console, and every certified handler
    -- or K9 gets a read-only view of their own record plus the ability to
    -- TRIGGER what they hold, as an alternative to keybinds and commands.
    -- It routes each action to the same client function the keybind calls
    -- rather than reimplementing it -- a forked entry point is how one path
    -- ends up guarded and the other does not, which this resource has
    -- already been bitten by once (ScratchAtDoor/NudgeDoor).
    -- NOTE this is the FIRST focus-taking NUI surface here. A stuck focus
    -- locks a player out of their own character, so the close path is
    -- deliberately singular: OpenTablet/CloseTablet are globals precisely so
    -- no other site calls SetNuiFocus itself. Its html assets are listed in
    -- files{} above once the UI lands.
    'client/tablet.lua',
    'client/vehicle.lua',
    'client/tracking.lua', -- Phase 2
    'client/scenttrail.lua', -- K9_IDEAS.md §2 "follow your nose" (ScentTrailHunt), client half. No load-order dependency: CanShowK9UI/DenyK9UIAccess/K9Sit/PlayK9Sound are all reached behind type() guards.
    'client/pursuitsprint.lua', -- K9_IDEAS.md §5 (PursuitSprint), client half. No load-order dependency.
    'client/scentlineup.lua', -- K9_IDEAS.md §4 (ScentLineup), client half -- the invite consent dialog only. Calls no other client file's globals, so no load-order dependency at all.
    'client/sarcalls.lua', -- K9_IDEAS.md §3 (SARCalls), client half. No load-order dependency: CanShowK9UI/DenyK9UIAccess/K9Sit/PlayK9Sound all go through runtime existence guards. Owns the cosmetic 'found them' reveal, which is non-networked and cleaned up by the same client that made it.
    'client/search.lua',   -- Phase 2
    'client/findalert.lua', -- K9_IDEAS.md §1 (FindAlerts), client half. Reuses client/main.lua's PlaySoundOnNetworkEntity at runtime only, so no load-order requirement beyond that file existing.
    'client/vision.lua',   -- Phase 2
    'client/hud.lua',      -- Phase 4
    'client/inventory.lua', -- Phase 4 (K9Inventory, PHASE4_SPEC.md §13.4.2)
    'client/kennel.lua',   -- Phase 5 R&D (DeployableKennel, phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research §5)
    'client/medkit.lua',   -- Phase 4 (K9Medkit, PHASE4_SPEC.md §13.4.4)
    'client/wellbeing.lua', -- Phase 4 (unified Fatigue/Mood/FearStress/Distraction/Injury subsystem, PHASE4_SPEC.md §13.0 Decision 1)
    'client/progression.lua', -- Phase 4 (XPProgression, PHASE4_SPEC.md §13.4.1)
    'client/combat.lua', -- Phase 3 (BiteAndHold/NonLethalTakedown, PHASE3_SPEC.md §12.5.1/§12.5.2) -- the client half of server/combat.lua; no ordering dependency on anything else in this list (reads Config.Combat/Config.Features from config.lua, already loaded via shared_scripts, and calls CanShowK9UI/DenyK9UIAccess from client/main.lua, which is loaded earlier in this same list, but Lua global-function resolution here is at CALL time, not load time, so this would still work even loaded first)
    'client/partnership.lua', -- Phase 3 (HandlerPartnership registry, PHASE3_SPEC.md §12.0 item 7/§12.3) -- the client half of server/partnership.lua (Partner Up consent prompt, ox_target option, IsPartnered()/GetPartnerServerId(), and RefreshPartnershipStateFromServer() which yields on a server callback to re-sync the local cache before a caller decides Partner Up vs Break Partnership -- the local cache alone can under-report after a reconnect. The radial entry is now wired, in client/radial.lua). Same "no ordering dependency" note as client/combat.lua above -- calls CanShowK9UI()/IsOwnModelK9() from client/main.lua only at CALL time (inside RequestPartnerUp/the ox_target predicate), never at file-load time.
    'client/defense.lua', -- Phase 3 HandlerDownDefense client half -- soft dependency on client/combat.lua's IsBiteHoldEngaged via a runtime existence guard, so no hard load-order requirement
    'client/propattachment.lua', -- Phase 5 R&D (PropAttachments). Also owns the generic AttachPropToOwnPed/DetachAndDeleteProp mechanic that client/bonetool.lua and client/fetch.lua both reuse rather than hand-rolling a third copy.
    'client/bonetool.lua',       -- Dev-only bone-index sweep (BoneSweepDevTool). Placed here for topical grouping only; calls propattachment's globals at runtime, so no load-order requirement.
    'client/fetch.lua',          -- Phase 5 (FetchMechanic). Loaded AFTER client/propattachment.lua deliberately: it reuses that file's AttachPropToOwnPed/DetachAndDeleteProp rather than hand-rolling a third prop-attach copy. A QA pass added a note here claiming this ordering was a HARD REQUIREMENT because the two globals are only defined inside propattachment's feature gate, making the flags coupled. THAT IS WRONG and is corrected here rather than left standing: AttachPropToOwnPed and DetachAndDeleteProp are defined at propattachment.lua:79 and :123, UNCONDITIONALLY -- the PropAttachments gate is at :174, after both, and that file's own header states plainly that neither function is gated. So the globals exist whenever the file loads, regardless of the flag. It IS true that client/fetch.lua calls them without a type() guard, so the load ORDER above still matters; the flags are NOT coupled and no nil-global call is reachable. Note what this feature is NOT -- the K9 does not walk the ball back on its own; it cannot, because the K9 is a connected player's character and nothing here scripts a player's ped movement. The return leg is a real, server-validated player action.
    'client/screenfx.lua', -- Phase 4 (ContrabandScreenFX). Held out of this manifest until its two timecycle natives were verified against primary source (no native is allowlisted here on an unverified assertion); both are now confirmed client-only. Registers its OWN handler for qbx_k9unit:client:applyContrabandScreenFx rather than extending client/search.lua -- an additional consumer, the same pattern server/wellbeing.lua and server/tracking.lua use for relayDamageEvent. No load-order dependency.
    'client/audio.lua', -- Phase 5 NUI audio bridge. The NUI audio bridge, and it is LIVE: client/main.lua's PlaySoundOnNetworkEntity calls PlayK9Sound() (guarded with type()), and all five sound keys this bridge can request now ship and are listed in this manifest's files{} block (see html/sounds/CREDITS.md for provenance and licensing). A key with no file degrades to a silent no-op end to end, which looks exactly like the feature being off -- so keep that list complete.
    'client/proximityaudio.lua', -- Phase 5 (ProximityAudioFX). Distance-scaled gain over client/audio.lua's NUI bridge, so it loads after it. Registers no net-event handlers at all -- a security sweep confirmed the forged-event class does not apply. Its sound, growl_ambient.ogg, now ships (Config.ProximityAudioFX.soundName -> ToAudioFileKey's lowercase fallback, not the SOUND_NAME_TO_FILE_KEY map).
    'client/recall.lua', -- Phase 3 Recall (client half). Exposes RequestRecall() and the k9recall command. Deliberately does NOT call CanShowK9UI()/DenyK9UIAccess() -- Recall is a TERMINATION path and gating one is how the unbounded trap this resource forbids gets built.
    'client/training.lua', -- Training Mode (FEATURE_IDEAS.md Part A Tier B §6) -- the client half of server/training.lua. Rehearses the search / bite-and-hold FLOW against a scripted fake server response inside a Config.TrainingZones area; never touches a real target and never mints XP (server/training.lua's THE XP DECISION section is the authority on why -- do not "restore" an award here). No load-order dependency: reaches the server only through lib.callback.await at call time.
    'client/equipmentshop.lua', -- K9 Supply shop walk-up (FEATURE_IDEAS.md Part B §6) -- the client half of server/equipmentshop.lua. Adds the ox_target marker ox_inventory's own RegisterShop does not create, then hands off to exports.ox_inventory:openInventory('shop', ...). Every price/permission decision stays inside ox_inventory's own server-side shop code; this file only opens the UI. No load-order dependency.
    'client/exports.lua', -- Public client-side export surface. No load-order dependency: every wrapped function is reached through a `type(fn) == 'function'` guard plus pcall, so an export over a file that early-returns under its own feature flag returns a documented nil/false rather than erroring.
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    -- REFACTOR_ROADMAP.md item 1: shared cooldown/mutex helper (NewCooldown/
    -- NewNestedCooldown/NewMutex), loaded FIRST among this resource's own
    -- files since main.lua/certifications.lua/tracking.lua/search.lua all
    -- call these resource-global constructors at their own file-load time.
    'server/cooldowns.lua',
    -- Live feature control (Config.Features.RuntimeFeatureControl). Loaded
    -- immediately after cooldowns.lua for two reasons, both hard: it calls
    -- NewCooldown at its own file-load time, and it must run BEFORE every
    -- feature file whose gate is evaluated at onResourceStart, so a
    -- persisted override from the tablet is already applied by the time
    -- those files read Config.Features. Later in this list and a toggle
    -- would silently not survive a restart.
    'server/runtimecontrol.lua',
    -- REFACTOR_ROADMAP.md near-term item 2: shared defensive netId->entity
    -- resolver (ResolveNetworkEntity), loaded alongside cooldowns.lua and
    -- before main.lua/search.lua, its two consumers.
    'server/entities.lua',
    -- Shared ox_lib notify wrapper (NotifyPlayer). Extracted after an audit
    -- found this pattern hand-rolled 12 separate times across server files --
    -- with real drift already visible between copies -- while the roadmap
    -- recorded it as "2 copies, closed". Loaded early alongside cooldowns.lua
    -- and entities.lua, the resource's other shared-helper files, since its
    -- consumers span nearly every server file below.
    'server/notify.lua',
    -- PD high command (Config.Features.HighCommand). Grouped with the shared
    -- helpers above rather than with the feature files below, because it is
    -- one: it exposes IsHighCommand(), which server/admin.lua,
    -- server/certifications.lua and server/bonetool.lua all consult so high
    -- command bypasses their own rank gates. Loading it before its consumers
    -- is a consistency choice, not a hard requirement -- every consumer
    -- guards the call with type(fn) == 'function', this resource's standard
    -- soft-dependency convention, so they still work with the feature off.
    -- It also owns /k9givexp and AwardXPDirect, the ONLY path in this
    -- resource that mints a caller-specified XP amount. server/progression's
    -- AwardXP deliberately takes a config-owned actionKey instead, so that
    -- no ordinary caller can name an amount; this one is bounded by
    -- Config.HighCommand.maxXpPerGrant and audited on every use.
    'server/highcommand.lua',
    -- Grantable permissions (Config.Features.PermissionGrants). Grouped with
    -- the shared helpers for the same reason highcommand.lua is: it exposes
    -- HasPermission(), which other server files consult behind the usual
    -- type(fn) == 'function' guard. Loaded after highcommand.lua because a
    -- permission check falls through to a high-command check when no grant
    -- exists; again a consistency choice, not a hard requirement, since the
    -- lookup happens at call time.
    -- Owns the k9_permissions table: both the four admin capabilities and
    -- the per-person feature grants and blocks, which share that table keyed
    -- feature.<Name> and block.<Name> so they inherit its audit trail and
    -- its one-active-row-per-key guarantee for free.
    -- K9 ROLE / PED ASSIGNMENT. This is what makes "everything works with
    -- any ped" true: the K9 role is a stored assignment, not a model
    -- lookup, so a role-holder on a custom streamed ped, a ped absent from
    -- Config.Peds, or a plain human model still gets K9 features. Exposes
    -- HasK9Role/GetAssignedK9Model/ApplyK9PedRole/ApplyK9AppearanceOnGrant/
    -- MaybeRevertK9Appearance.
    -- HARD load-order requirement on server/cooldowns.lua: NewCooldown is
    -- called at this file's own file-load time (line 156), not lazily.
    -- Placed before server/permissions.lua because that file calls two of
    -- these functions -- through a type(fn) == 'function' guard, so it is a
    -- soft dependency, but there is no reason to make the guard do that job.
    'server/appearance.lua',
    'server/permissions.lua',
    'server/main.lua',
    'server/certifications.lua',
    -- K9 COMMAND TABLET, server half. This is high command's actual control
    -- surface: the roster read side, plus tabletAssignK9Role and
    -- tabletRevertK9Ped -- assigning someone the K9 role and stripping it
    -- back to a human. It was written and never registered, so every one of
    -- those callbacks silently never answered. Loaded after
    -- server/permissions.lua and server/certifications.lua, whose
    -- IsHighCommand/HasPermission/HasK9Access it consults (21 call sites,
    -- all at runtime, so this is convention rather than a hard requirement).
    'server/tablet.lua',
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
    -- four call sites (a verification pass counted four, not the three an
    -- earlier revision of this comment claimed) guard the call with a
    -- `type(...) == 'function'`
    -- check rather than assuming load order, since by the time any of them
    -- can actually FIRE (a real player action), every server_scripts file
    -- below has already finished loading regardless of manifest order.
    'server/partnership.lua',
    -- Phase 3 HandlerDownDefense (PHASE3_SPEC.md §12.5.3) -- hard dependency on
    -- cooldowns.lua (NewCooldown at file-load time); reads partnership state via
    -- GetActivePartnerCitizenId, server-side only, never a client claim.
    'server/defense.lua',
    'server/tracking.lua', -- Phase 2
    'server/scenttrail.lua', -- K9_IDEAS.md §2 "follow your nose" (ScentTrailHunt), server half. HARD load-order dependency on server/cooldowns.lua -- NewCooldown at this file's own file-load time -- already satisfied here. Holds the hidden coordinate and never sends it to a client; only a distance goes over the wire.
    'server/pursuitsprint.lua', -- K9_IDEAS.md §5 (PursuitSprint), server half. HARD load-order dependency on server/cooldowns.lua (NewCooldown at file-load time). Also holds the only correct implementation of the four-step per-person FeatureControl resolution -- read it before writing a second one anywhere else.
    'server/scentlineup.lua', -- K9_IDEAS.md §4 (ScentLineup), server half. HARD load-order dependency on server/cooldowns.lua (NewCooldown at file-load time); NotifyPlayer/HasK9Access/HasPermission/K9Compat.Get are runtime-only. Holds the secret match and never sends it to any client until a pick is committed.
    'server/sarcalls.lua', -- K9_IDEAS.md §3 (SARCalls), server half. HARD load-order dependency on server/cooldowns.lua (NewCooldown at file-load time) and after server/certifications.lua for HasK9Access. AwardXP is behind a runtime guard, so no ordering against progression.lua. Holds the hidden target coordinate and never sends it to a client.
    'server/search.lua',   -- Phase 2
    'server/findalert.lua', -- K9_IDEAS.md §1 (FindAlerts), server half. An ADDITIONAL consumer of server/search.lua's searchCompleted and client/tracking.lua's reportTrackSourceArrival events -- it adds no detection logic of its own, which is why it needs no ordering against either. It DOES call NewCooldown at its own file-load time, so server/cooldowns.lua before it is a hard requirement; HasK9Access is runtime-only.
    'server/inventory.lua', -- Phase 4 (K9Inventory, PHASE4_SPEC.md §13.4.2)
    'server/kennel.lua',    -- Phase 5 R&D (DeployableKennel, phase2_notes/RESEARCH_ARCHIVE.md#phase-5-research §5) -- loaded after cooldowns.lua (NewCooldown at file-load time) and certifications.lua (HasK9Access)
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
    -- Phase 5 R&D (PropAttachments) and the dev-only bone-index sweep tool.
    -- Both call NewCooldown() at file-load time, so both MUST load after
    -- server/cooldowns.lua. Registered after a security review cleared all
    -- four files: the arbitrary-entity delete is closed, registration is
    -- gated on the feature flag rather than the handler self-rejecting, and
    -- the sweep tool is dual-gated (flag at command registration, ACE
    -- re-checked per invocation, console explicitly rejected).
    'server/propattachment.lua',
    'server/bonetool.lua',
    -- Phase 5 (FetchMechanic) server half. Loaded after cooldowns.lua
    -- (NewCooldown at file-load time -- hard requirement), entities.lua and
    -- certifications.lua. Never trusts a bare netId: every pickup/deliver
    -- request is resolved through ResolveNetworkEntity, model-checked against
    -- an allowlist, and cross-checked for equality against the server's own
    -- tracked ball. Every ball carries an absolute lifetime ceiling
    -- independent of any activity path, so none can outlive its cycle.
    'server/fetch.lua',
    'server/recall.lua',
    -- Partnership-tenure milestone XP bonus (Config.Features.PartnershipTenureBonus,
    -- FEATURE_IDEAS.md Part B item 7) -- the first gameplay consequence
    -- wired to the HandlerPartnership registry, which landed as a
    -- foundation with none. Extends partnership.lua/progression.lua through
    -- their already-exposed accessors; no load-order dependency on either.
    -- REQUIRES k9_partnerships.tenure_bonus_tier_granted (sql/install.sql
    -- for fresh installs, sql/migrations/0003_*.sql for existing ones);
    -- without it the milestone would re-grant on every restart, so its
    -- queries are pcall-wrapped and go inert rather than misbehaving.
    'server/tenure.lua',
    -- Read-only, POLICE-JOB-RANK-gated audit surface over the three tables this
    -- resource writes. Loaded after cooldowns.lua (NewCooldown at file-load
    -- time); deliberately does NOT call into certifications.lua or
    -- partnership.lua -- see its own ACCESS MODEL header.
    -- Training Mode server half (FEATURE_IDEAS.md Part A Tier B §6). HARD
    -- load-order requirement on server/cooldowns.lua: it calls NewCooldown()
    -- at THIS FILE'S OWN file-load time (twice -- ToggleCooldown and
    -- ActionCooldown), not lazily inside a handler, so cooldowns.lua being
    -- later in this list is a nil-call at start, not a degraded feature.
    -- HasK9Access (server/certifications.lua) is reached at runtime through a
    -- type(fn) == 'function' guard that fails CLOSED, so that one is a soft
    -- dependency; it is still listed after certifications.lua so the guard
    -- never actually has to do that job. Mints ZERO XP by construction and
    -- must stay that way -- a training dummy has less friction than any of
    -- the four real mechanics, so any award here would be reachable faster
    -- than the compound farm server/progression.lua's mint budget closed.
    'server/training.lua',
    -- /k9stats leaderboard (Config.Features.K9Leaderboard). Load-order:
    -- after server/cooldowns.lua, a HARD requirement whenever the feature
    -- flag is on -- it calls NewCooldown() at this file's own file-load
    -- time, immediately past its feature gate, not lazily inside the
    -- command handler. Also after server/certifications.lua, since
    -- HasK9Access(source) is the only gate on the command. Reads
    -- k9_progression through the idx_xp index added by SQL migration 0009;
    -- without that index the query is a full table scan plus a filesort on
    -- every engine, so do not remove it.
    'server/leaderboard.lua',
    -- K9 Supply shop registration (FEATURE_IDEAS.md Part B §6). Sells the
    -- item names this codebase already invented as documented placeholders
    -- with nowhere to buy them (k9_medkit / k9_treat / k9_meat_bait /
    -- k9_ultrasonic_whistle) -- it finishes a half-built loop rather than
    -- opening a new one. No load-order dependency (no NewCooldown/NewMutex at
    -- file-load time); the whole ox_inventory RegisterShop call is wrapped in
    -- pcall so an older/different RegisterShop shape degrades to one console
    -- line instead of failing resource start.
    'server/equipmentshop.lua',
    'server/admin.lua',
    -- Public server-side export surface -- this resource's first exports.
    -- Self-registers via the runtime `exports('name', fn)` call, so no
    -- `server_exports` manifest key is needed. Loaded last so every wrapped
    -- internal function is already defined, though each call is guarded
    -- anyway.
    -- External-system integration surface. Fires 'qbx_k9unit:events:k9Down'
    -- from a self-contained health-poll thread. Loaded after cooldowns.lua
    -- (NewCooldown at file-load time) and certifications.lua (HasK9Access
    -- and IsConfiguredK9Model, called at runtime).
    'server/integrations.lua',
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
-- GetShapeTestResult call (client/agility.lua's vault sweep -- moved there
-- from client/movement.lua) reads only
-- resultCode and hit -- never endCoords or surfaceNormal, the exact vector
-- returns reported broken by lua54 + fxv2_oal together on some builds.
-- If a future call here needs to read a shape-test or raycast vector result,
-- re-verify that known issue against the build in use FIRST.
use_experimental_fxv2_oal 'yes'
