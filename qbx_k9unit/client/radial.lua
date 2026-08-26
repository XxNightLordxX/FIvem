--[[
    qbx_k9unit/client/radial.lua

    Phase 1 scaffold. Thin ox_lib radial menu WIRING
    ONLY — this file must never implement anim/native gameplay logic
    directly. Every item's onSelect should do at most a cheap access check
    plus a single call into a global function exposed by client/main.lua,
    client/movement.lua, or client/vehicle.lua. If an item needs more than
    a couple of lines to decide what to do, that logic belongs in one of
    those files, not here — keeps this file from becoming an
    everything-file as later phases add more radial items.

    ======================================================================
    EVENT/CALLBACK CONTRACT — this file does not register or trigger any
    NETWORK event/callback directly (the one local-only exception, noted
    separately below this list, is an AddEventHandler for
    client/featureblocks.lua's purely client-side
    `qbx_k9unit:client:featureBlocksApplied` re-broadcast, which crosses no
    network boundary and needs no trust-boundary check). It calls:
      - client/main.lua's CanShowK9UI() to decide whether to show/allow
        the "K9 Unit" submenu at all.
      - client/movement.lua's ToggleK9Camera(), K9Sit(),
        RequestLeashAttach(targetServerId), DetachLeash(), IsLeashed().
      - client/vehicle.lua's EnterNearestK9Vehicle(), ExitK9Vehicle(),
        IsInK9Vehicle().
      - TriggerServerEvent('qbx_k9unit:server:relayBark', barkType) directly
        for the Bark item (the one place this file talks to the network
        itself, since there's no separate "bark module" file to delegate
        to — server/main.lua's relayBark handler is the other end).
      - client/partnership.lua's BreakPartnership(), RequestPartnerUp(targetServerId).
      - client/recall.lua's RequestRecall().
      - client/defense.lua's ConfirmHandlerDownDefense(actionType).
      - client/fetch.lua's RequestThrowFetchBall(), ReleaseFetchBall(),
        RequestRecallFetchBall(), IsFetchCarryEngaged().
      - client/propattachment.lua's RequestToggleK9PropAttachment().
      - client/kennel.lua's RequestDeployKennel().
      - client/inventory.lua's RequestOpenOwnK9Inventory().
      - client/medkit.lua's RequestTreatNearestK9().
      - client/main.lua's HasK9Access() directly (not just via CanShowK9UI())
        for two items — Fetch's Throw branch and Training's Start/Stop
        toggle's Start direction — whose own source files document that
        each is deliberately gated on HasK9Access() alone, not the full
        CanShowK9UI() combinator (see each item's own comment for why,
        quoting client/fetch.lua's RequestThrowFetchBall()/
        client/training.lua's RequestSetTrainingMode() verbatim).
      - client/sarcalls.lua's RequestStartSarCall(), RequestAbandonSarCall(),
        IsSarCallActive().
      - client/training.lua's IsTrainingModeActive(),
        RequestSetTrainingMode(desiredOn), RequestTrainingSearchDrill(),
        RequestTrainingBiteDrill().
      Every cross-file global added after Phase 1 is called behind
      a `type(fn) == 'function'` runtime existence guard (this codebase's
      established soft-dependency convention — see e.g. RestoreInjury/AwardXP
      in server/tracking.lua) because client/radial.lua loads FIRST among
      client_scripts (fxmanifest.lua), before every file listed above that
      defines one of these globals — the guard is never a load-order
      assumption, since by the time any of these onSelect closures actually
      RUNS (a player action, always well after this resource has finished
      loading), every one of those files has already executed and defined
      its own globals for real; it is kept anyway per this resource's own
      documented "runtime existence guard, not a load-order assumption"
      convention, matching every other guarded call site in this codebase.
    ======================================================================

    DEVELOPER_REFERENCE.md §6.1 / §8 step 7 Phase 1 radial item list: Bark, Sit,
    Attach/Detach Leash, Enter/Exit Vehicle — "each item only appears if
    its owning Config.Features flag is true AND the access check above
    passes."

    STRUCTURAL QUESTION, RESOLVED (see "OPEN STRUCTURAL QUESTION
    resolution" below, right before FindNearestLeashCandidate()): ox_lib's
    `lib.addRadialItem` registers items once; there's no built-in live
    "should this item be visible right now" predicate the way ox_target's
    `canInteract` works. Two ways to satisfy "each item only appears
    if... access check passes" (DEVELOPER_REFERENCE.md §3/§6.1):
      (a) A lightweight polling thread (e.g. every 2-3s while the local
          player is near/playing) that calls CanShowK9UI() and
          lib.addRadialItem/lib.removeRadialItem the whole "K9 Unit"
          submenu in/out of existence accordingly.
      (b) Register the submenu once, unconditionally, and gate purely
          inside each onSelect via CanShowK9UI() (and the item's own
          Config.Features flag), notifying+denying on failure — the menu
          entry always "appears" but does nothing for a non-qualifying
          player.
    DEVELOPER_REFERENCE.md's "only appears if" phrasing leans toward (a), but a live
    network round-trip (CanShowK9UI awaits a server callback) firing every
    couple of seconds for every player near a PD is more chatter than
    wanted — (b) is what this file implements; see the resolution comment
    below for the full reasoning. Documented here so "appears" in this
    file's own comments is understood to mean "is present in the radial
    wheel," not "is currently usable."

    QBOX/OX_LIB API FIX (verified against ox_lib's actual source —
    overextended/ox_lib
    resource/interface/client/radial.lua's registerRadial/addRadialItem/
    radialClick — not just the docs prose): the earlier draft of this file
    built ONE FLAT ARRAY containing an "opener" item (id='k9unit', no
    onSelect, no menu) plus the four action items, each of THOSE carrying
    `menu = 'k9unit'`, and passed the whole array to a single
    `lib.addRadialItem(k9RadialItems)` call with no `parentMenuId` and no
    matching `lib.registerRadial` call anywhere. That is not what `menu`
    means on an item: `menu` does not mean "this item lives inside
    submenu X" (grouping), it means "selecting this item navigates to the
    ALREADY-REGISTERED submenu with this id" — ox_lib's own radialClick
    NUI handler runs `if item.menu then ... showRadial(item.menu) end`
    BEFORE it ever calls the item's own `onSelect`, and `showRadial` on an
    id nobody registered via `lib.registerRadial` does
    `return error('No radial menu with such id found.')` — a hard Lua
    error that aborts the callback right there, so `onSelect` (the line
    that would have actually run K9Sit()/relayBark/RequestLeashAttach()/
    EnterNearestK9Vehicle()) never executes at all. On top of that, with
    no `parentMenuId` every one of these items (including the would-be
    "opener") lands in the GLOBAL root wheel `menuItems`, not tucked under
    a submenu — mixed in with every other resource's global radial items,
    not the single "K9 Unit" icon the rest of this file's comments
    describe. Net effect of the old code: every Phase 1 radial action was
    completely non-functional (hard error on select), not merely
    mis-labeled. Fixed below by actually calling `lib.registerRadial({id
    = 'k9unit', items = k9SubmenuItems})` for the real submenu contents
    (none of which carry their own `menu` field — they're terminal
    actions, not further navigation links) and a separate
    `lib.addRadialItem({...})` call for the single opener item that
    carries `menu = 'k9unit'` to link into it. Option (b)'s reasoning
    above (register unconditionally, gate in onSelect) is unchanged by
    this fix — only the registration mechanics were wrong, not the
    gating design.

    BARK TYPE NOTE: Phase 1 needs exactly one generic bark (§6.1: "Basic
    bark sound plays on a radial-triggered 'Bark' action" — the
    aggressive/alert/calm variety is Phase 5's AdvancedBarkRadial, not
    Phase 1). Use a single literal string, e.g. 'bark', consistently with
    server/main.lua's relayBark handler and client/main.lua's playBark
    handler — all three call sites must agree on the same literal.

    UPDATE (Phase 5, AdvancedBarkRadial implemented): when
    Config.Features.AdvancedBarkRadial is also true (still requires
    BasicBarkSounds underneath it), the Bark item below becomes a submenu of
    config-driven variants (Config.AdvancedBarkRadial, config.lua) instead of
    that single literal — see the Bark block below for the full contract.
    Every variant still triggers the exact same
    'qbx_k9unit:server:relayBark' event, just with a different `barkType`
    string; server/main.lua's handler was NOT changed for this, it already
    accepts any opaque, length-capped barkType. When AdvancedBarkRadial is
    off (the default), behavior is unchanged from the single-literal
    description above.

    OX_LIB RESTART LIFECYCLE FIX (verified against ox_lib's own source --
    overextended/ox_lib resource/interface/client/radial.lua, read
    directly): every `lib.registerRadial`/`lib.addRadialItem` call this file
    makes used to run ONCE, at this file's own load time, as bare top-level
    statements. That was fine for THIS resource's own lifecycle
    (fxmanifest.lua only loads this file once per resource start), but
    ox_lib keeps `menus` and `menuItems` -- the tables every one of those
    calls writes into -- as plain FILE-LOCAL Lua tables inside ox_lib's OWN
    client chunk, exactly the same shape client/movement.lua's own
    "LIFECYCLE FIX" comment documents for ox_target's
    addGlobalPlayer/addGlobalObject registries. ox_lib's
    `onClientResourceStop` handler only clears `menuItems` entries
    belonging to the STOPPING resource -- it never touches `menus` at all --
    but neither table survives ox_lib ITSELF restarting: that reloads the
    whole chunk from scratch, reconstructing both empty, with nothing in
    ox_lib re-populating them and nothing in the old version of this file
    ever prompting a re-add. The entire "K9 Unit" radial menu -- submenu,
    every nested submenu, and the root opener -- would silently vanish the
    moment ox_lib restarts, no error, no log line; and if the (now
    unregistered) 'k9unit'/'k9unit_bark'/'k9unit_defense'/'k9unit_fetch' ids
    were ever still referenced via a stale `menu` field somewhere,
    ox_lib's `showRadial` does `return error('No radial menu with such id
    found.')` -- an UNCAUGHT hard Lua error, not a no-op.

    FIX: every registration call in this file now lives inside one
    idempotent function, RegisterK9RadialMenu() (see its own doc comment,
    right where it's defined, for the full writeup) -- called from a single
    `AddEventHandler('onResourceStart', ...)` dispatcher at the bottom of
    this file that fires on EITHER this resource's own start OR ox_lib's,
    mirroring the exact `resourceName == GetCurrentResourceName() or
    resourceName == '<dependency>'` idiom already established for ox_target
    in client/movement.lua/client/fetch.lua/client/medkit.lua/
    client/wellbeing.lua/client/search.lua -- just pointed at 'ox_lib'
    instead, since it's ox_lib's own registries this file's state lives
    inside. Verified idempotent against ox_lib's real dedup behavior (both
    `lib.registerRadial`'s key-based table write and `lib.addRadialItem`'s
    id-match replace-in-place never duplicate an entry on a repeat call --
    see RegisterK9RadialMenu()'s own comment for the full verification).
]]

-- OPEN STRUCTURAL QUESTION resolution: option (b) was chosen — the "K9
-- Unit" submenu and its sub-items are registered ONCE, unconditionally
-- (subject to each item's own Config.Features flag at registration time,
-- satisfying DEVELOPER_REFERENCE.md §3's "read at the point... menu item visibility"),
-- and every onSelect below independently re-checks CanShowK9UI() before
-- doing anything, notifying+denying on failure. Rationale for (b) over
-- (a): every onSelect's own "if not CanShowK9UI() then notify + return"
-- shape only makes sense if the item can actually be seen/selected by a
-- non-qualifying player in the first place; (a) would make that branch
-- largely unreachable. (b) also avoids a polling thread that would
-- otherwise re-await the server's hasK9Access callback every couple of
-- seconds for every player near a PD. (NOTE: the actual
-- lib.registerRadial/lib.addRadialItem submenu-then-children mechanics
-- were separately verified against ox_lib's own source — see the
-- QBOX/OX_LIB API FIX note above — which found the original registration
-- call itself was broken; that is fixed independently of this
-- option-(b)-vs-(a) choice, which still stands.) "Appears" in this file's
-- own comments means "is present in the radial wheel," not "is currently
-- usable" — usability is enforced at onSelect time, same as every gated
-- server event is independently re-verified server-side regardless of
-- what the client shows.
--- Finds the nearest OTHER player within Config.LeashMaxDistance (the base
--- leash range, reused directly here as a search radius rather than via
--- a derived factor — see config.lua's comment on that field and
--- server/main.lua's header for the initiate-range check this mirrors),
--- for the Attach/Detach Leash radial item's self-initiated entry point.
--- Model plausibility isn't filtered here — the server independently
--- re-validates via CheckLeashEligibility (server/main.lua) regardless.
--- @return number? candidateServerId
--- SEAM OPENED 2026-08-25: was `local`. client/tablet.lua calls this so the
--- tablet's own action routes through the SAME candidate-resolution logic the
--- radial uses, rather than carrying a second copy that would drift out of
--- sync the first time either is fixed. Kept a plain global to match this
--- resource's existing cross-file convention; callers guard with
--- type(fn) == 'function' since client/radial.lua returns early when its own
--- feature flag is off, in which case this is never defined.
function FindNearestLeashCandidate()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPlayer, nearestDist

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= PlayerId() then
            local targetPed = GetPlayerPed(playerId)
            if targetPed ~= 0 and DoesEntityExist(targetPed) then
                local dist = #(myCoords - GetEntityCoords(targetPed))
                if dist <= Config.LeashMaxDistance and (not nearestDist or dist < nearestDist) then
                    nearestPlayer, nearestDist = playerId, dist
                end
            end
        end
    end

    if not nearestPlayer then return nil end
    return GetPlayerServerId(nearestPlayer)
end

--- Same shape as FindNearestLeashCandidate() above, for the Partner Up
--- radial item's self-initiated entry point: nearest OTHER player within
--- Config.Partnership.ProximityMeters — that field is the REAL server-side
--- range client/partnership.lua's CheckPartnershipEligibility checks a
--- request against (both at request time and again at accept time), reused
--- directly here as the search radius for the identical reason
--- FindNearestLeashCandidate() reuses Config.LeashMaxDistance. No client-side
--- model plausibility filter (unlike client/partnership.lua's own ox_target
--- "Partner Up" predicate, which additionally requires at least one side to
--- plausibly be a K9) — this is a display-adjacent candidate pick, not a
--- security boundary, and CheckPartnershipEligibility re-derives the real
--- model server-side regardless.
--- @return number? candidateServerId
--- SEAM OPENED 2026-08-25: was `local`. client/tablet.lua calls this so the
--- tablet's own action routes through the SAME candidate-resolution logic the
--- radial uses, rather than carrying a second copy that would drift out of
--- sync the first time either is fixed. Kept a plain global to match this
--- resource's existing cross-file convention; callers guard with
--- type(fn) == 'function' since client/radial.lua returns early when its own
--- feature flag is off, in which case this is never defined.
function FindNearestPartnerCandidate()
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local nearestPlayer, nearestDist

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= PlayerId() then
            local targetPed = GetPlayerPed(playerId)
            if targetPed ~= 0 and DoesEntityExist(targetPed) then
                local dist = #(myCoords - GetEntityCoords(targetPed))
                if dist <= Config.Partnership.ProximityMeters and (not nearestDist or dist < nearestDist) then
                    nearestPlayer, nearestDist = playerId, dist
                end
            end
        end
    end

    if not nearestPlayer then return nil end
    return GetPlayerServerId(nearestPlayer)
end

--- Idempotent (re-)registration of every "K9 Unit" radial menu and
--- submenu this resource owns.
---
--- LIFECYCLE FIX (verified against ox_lib's own source --
--- overextended/ox_lib resource/interface/client/radial.lua, read
--- directly, not assumed): `menus` and `menuItems` inside that file are
--- plain FILE-LOCAL Lua tables in ox_lib's own client chunk, exactly the
--- same shape as ox_target's addGlobalPlayer/addGlobalObject registries
--- (see client/movement.lua's own "LIFECYCLE FIX" comment on
--- RegisterLeashOxTargetOption for that precedent, and client/fetch.lua's/
--- client/medkit.lua's/client/wellbeing.lua's/client/search.lua's matching
--- fixes for the identical bug class against ox_target). ox_lib's own
--- `AddEventHandler('onClientResourceStop', ...)` handler only clears
--- entries out of `menuItems` (the flat root wheel) belonging to the
--- STOPPING resource -- it never touches `menus` (the registerRadial
--- registry) at all, for ANY resource, ever. Neither table survives ox_lib
--- ITSELF restarting: a `restart ox_lib` reloads that whole client chunk
--- from scratch, reconstructing both `menus = {}` and `menuItems = {}`
--- empty, with nothing in ox_lib's own code re-populating them and nothing
--- in the old (pre-fix) version of this file ever prompting a re-add. The
--- entire "K9 Unit" radial menu -- the submenu itself, every nested
--- submenu, and the single root opener that links to it -- would silently
--- vanish the instant ox_lib restarts, with no error and no log line: the
--- player just finds the wheel gone (or, if this file's own opener item
--- happened to still be clicked via some other stale reference, ox_lib's
--- `showRadial` does `return error('No radial menu with such id found.')`
--- on any id nobody re-registered -- an UNCAUGHT hard Lua error, not a
--- no-op).
---
--- FIX: every `lib.registerRadial`/`lib.addRadialItem` call this file makes
--- now lives inside this one function, with the sole call site (the
--- `AddEventHandler('onResourceStart', ...)` dispatcher immediately below
--- this function) firing on EITHER this resource's own start OR ox_lib's,
--- same two-branch `resourceName == GetCurrentResourceName() or
--- resourceName == '<dependency>'` idiom already established at
--- client/movement.lua's "Sole call site for RegisterLeashOxTargetOption()"
--- comment (and its `ox_target` siblings in the four files named above) --
--- just pointed at `ox_lib` instead of `ox_target`, since it's ox_lib's
--- registries this file's own state lives inside, not ox_target's.
---
--- ORDERING PRESERVED: this function still registers every submenu
--- ('k9unit_bark', 'k9unit_defense', 'k9unit_fetch') strictly BEFORE the
--- 'k9unit' registration that follows it and BEFORE the root opener
--- `lib.addRadialItem` call at the very end -- i.e. before anything that
--- references one of those submenu ids via an item's `menu` field. This
--- matters even on a RE-registration, not just the first one: `menu`
--- navigation is resolved against ox_lib's live `menus` table at CLICK
--- time (`showRadial` does `local radial = id and menus[id]`), so as long as
--- every submenu this function registers lands in `menus` before this
--- function returns and control is handed back to the player, click-time
--- order never matters -- only that no submenu is EVER left permanently
--- unregistered while something still points at it. The straight-line
--- top-to-bottom statement order below is unchanged from before this fix
--- (see the file-level "QBOX/OX_LIB API FIX" note above for why that order
--- is itself correct); this function only adds a name and a second/third
--- call site around it, nothing about the registration sequence itself was
--- reordered.
---
--- DUPLICATE-VS-REPLACE (verified against ox_lib's own source):
--- `lib.registerRadial` does `menus[radial.id] = radial` -- a plain
--- key-based table write, so re-running this function against a `menus`
--- table that already holds an entry for a given id (this resource's own
--- restart, without ox_lib itself having restarted) REPLACES that entry
--- wholesale with a freshly-built table, never duplicates or appends
--- anything. `lib.addRadialItem` (used here only for the single
--- 'k9unit_open' root opener) walks its target array looking for a
--- matching `id` and replaces in place if found, only appending when no
--- match exists -- so the opener is likewise never duplicated on a repeat
--- call. Every item built inside this function always carries a fixed,
--- literal `id` (never a generated/random one), which is what makes both
--- of ox_lib's own dedup mechanisms actually apply here.
---
--- NOTHING ELSE in this file needs invalidation handling on an ox_lib
--- restart: the only ox_lib state this file ever holds onto is the
--- registration calls themselves (rebuilt fresh, from scratch, every single
--- time this function runs -- `k9SubmenuItems` and friends below are local
--- to this function, never module-level state that could go stale) and the
--- one-shot `locale()`/`lib.notify` calls each onSelect closure makes at
--- CLICK time, which need no persistent handle to ox_lib at all.
--- ======================================================================
--- K9 UNIT RADIAL -- PER-PERSON BLOCK (client/featureblocks.lua -- see
--- that file's own header for the full contract). RadialMenu and
--- AdvancedBarkRadial are the only two of the twelve purely-client-side
--- features made blockable that live in THIS file, and both are handled
--- the SAME way, deliberately DIFFERENT from how every other blockable
--- feature elsewhere in this codebase is handled: at REGISTRATION time
--- inside RegisterK9RadialMenu() below, not inside an onSelect closure.
--- WHY THIS ONE FILE IS THE EXCEPTION (see client/featureblocks.lua's own
--- header "WHERE THE CHECK GOES" for the short version): both features
--- are themselves about what this file's OWN registration STRUCTURE looks
--- like (does the K9 Unit wheel exist for this client at all; does its
--- Bark entry expand into a variant submenu) -- not about a single
--- ability's own point-of-use the way ThermalVision/VehicleEntryExit/etc.
--- are. Gating ~17 individual onSelect closures instead (adding a second,
--- independent block check to EVERY item's own already-carefully-tuned
--- initiation-vs-termination gate) would have meant re-auditing every one
--- of Detach Leash/Release Bite & Hold/Release Drag/Break Partnership/
--- Recall/Fetch's Release+Recall/every Stop Tracking branch by hand to
--- make sure a NEW check could never land on one of them by mistake -- a
--- real risk on a file this size, for no honesty benefit over the simpler
--- alternative below (this file's header "DUPLICATE-VS-REPLACE" note
--- already proves the alternative is safe to lean on).
---
--- RadialMenu BLOCKED: the 'k9unit' submenu contents stop being registered
--- (harmless -- nothing links to it, same disclosed nuance the GLOBAL
--- Config.Features.RadialMenu=false path already has). The single root
--- OPENER item, unlike the submenu, STAYS VISIBLE -- it is REPLACED
--- in-place (never removed) with a version carrying no `menu` field and an
--- onSelect that explains the block, rather than one that silently
--- vanishes. THIS IS A DELIBERATE, DISCLOSED COMPROMISE, not the ideal:
--- the fully-honest "icon disappears entirely" behavior would need a
--- REMOVAL call this codebase has never verified as real against ox_lib's
--- own source (a prior draft of this file's header floated
--- `lib.removeRadialItem` as a hypothetical, unconfirmed option) --
--- `lib.registerRadial`/`lib.addRadialItem`'s own REGISTER/REPLACE
--- semantics ARE independently verified (see "DUPLICATE-VS-REPLACE"
--- above), so this design stays entirely within what is actually proven,
--- rather than assuming an unverified native/API call the way this
--- resource's own established discipline forbids elsewhere. Every OTHER
--- ability normally reached through the wheel stays fully reachable via
--- every OTHER surface (keybind, command, tablet trigger, export) -- a
--- RadialMenu block closes only this one entry point's USEFULNESS, never
--- an ability itself, and is still strictly more honest than gating every
--- individual onSelect would have been (nobody sees SOME items work and
--- others silently refuse inside the same open wheel -- the ONE entry
--- point itself says plainly why it does nothing).
---
--- AdvancedBarkRadial BLOCKED (while BasicBarkSounds/RadialMenu are NOT):
--- the Bark entry degrades to the SAME single, flat, generic-'bark'-type
--- item this file already ships when Config.Features.AdvancedBarkRadial
--- is globally false -- barking itself keeps working (BasicBarkSounds has
--- its OWN, separate, server-enforced block key, untouched here), only the
--- variant SUBMENU is withheld.
---
--- LIVE, NOT JUST AT NEXT RESTART: client/featureblocks.lua fires a local
--- `qbx_k9unit:client:featureBlocksApplied` event every time it processes
--- a server sync -- this file's own listener (see the bottom of this
--- file, alongside the existing onResourceStart/ox_lib dispatcher) simply
--- calls RegisterK9RadialMenu() again, which re-evaluates both conditions
--- below fresh and REPLACES the previous registration in place (never
--- duplicates -- see "DUPLICATE-VS-REPLACE" above). One disclosed, minor
--- edge case: a player with the radial UI already open, mid-navigation,
--- at the exact instant a rebuild lands could have that one click resolve
--- against whichever registration (old or new) ox_lib's `menus` table
--- holds at that exact frame (navigation is resolved live, at click time,
--- per "ORDERING PRESERVED" above) -- not a crash, not a security concern,
--- just a possible one-frame staleness on an already-rare coincidence.
---
--- `type(IsK9FeatureBlocked) == 'function'` guard throughout, per this
--- resource's soft-dependency convention -- fails OPEN (never blocked) if
--- client/featureblocks.lua has not loaded, matching every other call
--- site in this file.
--- @param featureName string -- 'RadialMenu' | 'AdvancedBarkRadial'
--- @return boolean
local function IsRadialFeatureBlockedForMe(featureName)
    return type(IsK9FeatureBlocked) == 'function' and IsK9FeatureBlocked(featureName)
end

local function RegisterK9RadialMenu()
    -- Contents of the "K9 Unit" SUBMENU (registered via lib.registerRadial
    -- below) — none of these carry their own `menu` field. On an item, `menu`
    -- means "selecting this navigates to another already-registered menu,"
    -- not "this item belongs to submenu X" — see this file's header for the
    -- verified ox_lib source behind that distinction. These are terminal
    -- actions with their own onSelect, so `menu` must stay unset on all of
    -- them.
    local k9SubmenuItems = {
        --- Sit — DEVELOPER_REFERENCE.md §6.1. No dedicated Config.Features flag (bundled
        --- under the general RadialMenu flag + access check, same as every
        --- other Phase 1 item here).
        {
            id = 'k9_sit',
            label = locale('radial.sit_label'),
            icon = 'couch',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end
                -- type(...) == 'function' guard per this file's own header
                -- policy ("every cross-file global... called behind a
                -- type(fn) == 'function' runtime existence guard") --
                -- HEADER/CODE DRIFT FIX: this call, and every other one
                -- this fix touches below, used to call straight through
                -- unguarded, contradicting that stated blanket policy even
                -- though it was never actually reachable with a nil target
                -- in a real session (fxmanifest.lua loads
                -- client/movement.lua before any player action can fire
                -- this onSelect). Added for consistency with every other
                -- post-Phase-1 item in this file, and so the header's own
                -- claim is no longer false.
                if type(K9Sit) == 'function' then
                    K9Sit()
                end
            end,
        },
    }

    --- Bark — DEVELOPER_REFERENCE.md §6.1, §8 step 9. Config.Features.BasicBarkSounds gate.
    ---
    --- Phase 5's AdvancedBarkRadial (Config.Features.AdvancedBarkRadial, layered
    --- ON TOP of BasicBarkSounds — still requires it, matching how this resource
    --- layers every Phase 5 feature over its Phase 1 prerequisite elsewhere,
    --- e.g. ScentTracking/BloodTracking/GunpowderSniffing each standing alone
    --- under RadialMenu) swaps the single generic "Bark" action for a nested
    --- submenu of variants (Config.AdvancedBarkRadial, config.lua — DEVELOPER_REFERENCE.md
    --- §6.7: "aggressive/alert/calm"). Every variant still funnels through the
    --- SAME 'qbx_k9unit:server:relayBark' event with its own `barkType` string —
    --- server/main.lua's handler is UNCHANGED for this feature; it already
    --- accepts any opaque, length-capped barkType (BARK_TYPE_MAX_LENGTH = 16)
    --- with no enum validation, exactly the shape this needs. When
    --- AdvancedBarkRadial is off, behavior is byte-for-byte the same as before
    --- this feature existed: a single 'k9_bark' action sending the literal
    --- 'bark' string.
    if Config.Features.BasicBarkSounds then
        -- Per-person block on the ADVANCED VARIANT SUBMENU specifically --
        -- see this function's own "K9 UNIT RADIAL -- PER-PERSON BLOCK"
        -- header above. Basic barking (the `else` branch below) is
        -- unaffected either way.
        if Config.Features.AdvancedBarkRadial and not IsRadialFeatureBlockedForMe('AdvancedBarkRadial') then
            -- Build the nested submenu's terminal action items from
            -- config.lua's Config.AdvancedBarkRadial list. Each `variant` here
            -- is a FRESH local per loop iteration (Lua's generic `for` rebinds
            -- its control variables every pass), so each onSelect closure
            -- safely captures its own variant, not a shared/last-iteration one.
            local barkSubmenuItems = {}
            for _, variant in ipairs(Config.AdvancedBarkRadial) do
                barkSubmenuItems[#barkSubmenuItems + 1] = {
                    id = 'k9_bark_' .. variant.barkType,
                    label = variant.label,
                    icon = variant.icon,
                    onSelect = function()
                        if not CanShowK9UI() then
                            DenyK9UIAccess()
                            return
                        end
                        -- server re-validates Config.Features.BasicBarkSounds and
                        -- HasK9Access independently regardless — see server/main.lua.
                        TriggerServerEvent('qbx_k9unit:server:relayBark', variant.barkType)
                    end,
                }
            end

            lib.registerRadial({
                id = 'k9unit_bark',
                items = barkSubmenuItems,
            })

    -- K9 Command Tablet. Deliberately FIRST in the submenu: for a handler
    -- who does not want to learn keybinds, this one entry reaches every
    -- other ability, so burying it under them would be backwards.
    -- Guarded with type() because client/tablet.lua returns early when
    -- Config.Features.CommandTablet is off, in which case OpenTablet is
    -- never defined. The tablet itself re-checks authorization; opening it
    -- is not a privileged act, and a handler who is not certified still
    -- opens it and is shown WHY rather than finding a dead menu entry.
    if Config.Features.CommandTablet then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_open_tablet',
            label = locale('radial.tablet_label'),
            icon = 'tablet',
            onSelect = function()
                if type(OpenTablet) == 'function' then OpenTablet() end
            end,
        }
    end

            -- Opener item inside the "K9 Unit" submenu: selecting THIS navigates
            -- into 'k9unit_bark' (registered just above), same `menu`-field
            -- navigation mechanic this file's header already documents for the
            -- top-level 'k9unit_open' opener — this item carries no onSelect of
            -- its own on purpose.
            k9SubmenuItems[#k9SubmenuItems + 1] = {
                id = 'k9_bark',
                label = locale('radial.bark_label'),
                icon = 'volume-high',
                menu = 'k9unit_bark',
            }
        else
            k9SubmenuItems[#k9SubmenuItems + 1] = {
                id = 'k9_bark',
                label = locale('radial.bark_label'),
                icon = 'volume-high',
                onSelect = function()
                    if not CanShowK9UI() then
                        DenyK9UIAccess()
                        return
                    end
                    -- server re-validates Config.Features.BasicBarkSounds and
                    -- HasK9Access independently regardless — see server/main.lua.
                    TriggerServerEvent('qbx_k9unit:server:relayBark', 'bark')
                end,
            }
        end
    end

    --- Attach/Detach Leash — DEVELOPER_REFERENCE.md §6.1, §8 step 6-7. A single
    --- context-sensitive item: behaves as "Attach" when not currently
    --- leashed, "Detach" when leashed. Config.Features.LeashMechanics gate.
    --- See client/movement.lua's header for the full consent-based leash
    --- design (attach requires the OTHER player to accept; detach never
    --- does) — this item is one of two entry points into that same system
    --- (the other being the ox_target option client/movement.lua registers
    --- directly on nearby players).
    ---
    --- BUG FIX -- ITEM PRESENCE MUST NOT DEPEND ON THE FLAG ALONE ANYMORE:
    --- this used to be `if Config.Features.LeashMechanics then`, full stop
    --- — gating the item's very EXISTENCE in the menu on THIS CLIENT's own
    --- local copy of the flag, captured once at this client's own resource
    --- start (or the last featureBlocksApplied/ox_lib-restart rebuild) and
    --- never updated again for an already-connected client, even though
    --- server/runtimecontrol.lua's runtimeSetFeature can flip the
    --- server-side flag live at any time. A server that booted with
    --- LeashMechanics off, was flipped on live, formed a real pairing
    --- (server/main.lua's CheckLeashEligibility re-checks the flag LIVE,
    --- server-side — nothing client-side stopped the pairing from forming)
    --- left an actually-leashed player with no "Detach" item anywhere in
    --- their own radial menu: the button to press did not exist, and their
    --- only way out was client/movement.lua's elastic pull-back safety
    --- valve (walk far enough away) or a death/disconnect/resource
    --- restart — never an acceptable substitute for a deliberate manual
    --- detach. FIXED by widening this gate to `Config.Features.LeashMechanics
    --- OR IsLeashed()`: the item now also appears whenever this client is
    --- ACTUALLY leashed right now, regardless of what its own local flag
    --- copy says — a detach button should exist because you are on a
    --- leash, not because a setting says leashes exist. The ADD path
    --- inside onSelect below is UNCHANGED and still funnels through
    --- RequestLeashAttach()'s own CanShowK9UI()/IsOwnModelK9() checks and
    --- CheckLeashEligibility's own live, authoritative, server-side flag
    --- re-check either way, so widening this gate creates no new way to
    --- start a leash the flag/eligibility rules would otherwise refuse.
    --- See client/movement.lua's own 'qbx_k9unit:client:leashStateChanged'
    --- local re-broadcast (fired from its leashAttached/leashDetached
    --- handlers) and this file's own listener near the bottom for how this
    --- item's presence is actually kept live, tick to tick, rather than
    --- only at the rare moments RegisterK9RadialMenu() would otherwise run.
    if Config.Features.LeashMechanics or (type(IsLeashed) == 'function' and IsLeashed()) then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_leash',
            label = locale('radial.leash_toggle_label'),
            icon = 'link',
            onSelect = function()
                -- Detach never requires consent/access — always available
                -- while leashed, per DEVELOPER_REFERENCE.md §9 item 3b's hard requirement.
                -- type(...) == 'function' guards added below per this
                -- file's own header policy -- see k9_sit's identical note
                -- above for the full HEADER/CODE DRIFT FIX writeup. A
                -- absent IsLeashed() is treated as "not currently leashed"
                -- (falls through to the Attach branch), same short-circuit
                -- shape client/radial.lua already uses for
                -- IsFetchCarryEngaged() further down this file.
                if type(IsLeashed) == 'function' and IsLeashed() then
                    if type(DetachLeash) == 'function' then
                        DetachLeash()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                local candidateServerId = FindNearestLeashCandidate()
                if not candidateServerId then
                    lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_leash_candidate'), type = 'error' })
                    return
                end

                -- This only SENDS a request — per the consent design, nothing
                -- attaches until the target accepts on their own client.
                -- RequestLeashAttach() itself notifies "request sent."
                if type(RequestLeashAttach) == 'function' then
                    RequestLeashAttach(candidateServerId)
                end
            end,
        }
    end

    --- Enter/Exit Vehicle — DEVELOPER_REFERENCE.md §6.1, §8 step 8. A single
    --- context-sensitive item mirroring the ox_target vehicle option
    --- client/vehicle.lua registers directly. Config.Features.VehicleEntryExit
    --- gate.
    if Config.Features.VehicleEntryExit then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_vehicle',
            label = locale('radial.vehicle_toggle_label'),
            icon = 'car',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup. An
                -- absent IsInK9Vehicle() is treated as "not currently in a
                -- K9 vehicle" (falls through to the Enter branch).
                if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then
                    if type(ExitK9Vehicle) == 'function' then
                        ExitK9Vehicle()
                    end
                else
                    if type(EnterNearestK9Vehicle) == 'function' then
                        EnterNearestK9Vehicle()
                    end
                end
            end,
        }
    end

    --- Track Scent/Blood/Gunpowder — DEVELOPER_REFERENCE.md §11.3/§11.5, Phase 2. Each is a
    --- single context-sensitive item: while a trail of THAT SPECIFIC type is
    --- active it becomes a "Stop Tracking" cancel (calling the shared
    --- StopTracking()); while tracking a DIFFERENT type is active, it defers to
    --- Start*Track()'s own "already tracking — stop first" rejection/notify
    --- rather than silently canceling the wrong trail; otherwise it starts that
    --- specific trail type. This is the only in-game entry point to
    --- client/tracking.lua's Start*Track()/StopTracking() globals.
    --- A bare `if IsTracking() then StopTracking()` check here (not gated on
    --- the item's OWN type) would mean clicking, say, "Track Gunpowder"
    --- while already tracking blood would silently cancel the blood trail
    --- and do nothing else — the click swallowed by the wrong item's toggle
    --- branch, with zero notification, and Track Gunpowder needing a SECOND
    --- click to actually start. Avoided via GetActiveTrackType() — each item
    --- only self-toggles when it's already the active type. Each gated
    --- independently by its own Config.Features flag, same pattern as
    --- Bark/Leash/Vehicle above.
    if Config.Features.ScentTracking then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_track_scent',
            label = locale('radial.track_scent_label'),
            icon = 'wind',
            onSelect = function()
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup. An
                -- absent GetActiveTrackType() is treated as "nothing active"
                -- (falls through to the Start branch).
                if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'scent' then
                    if type(StopTracking) == 'function' then
                        StopTracking()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(StartScentTrack) == 'function' then
                    StartScentTrack()
                end
            end,
        }
    end

    if Config.Features.BloodTracking then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_track_blood',
            label = locale('radial.track_blood_label'),
            icon = 'droplet',
            onSelect = function()
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'blood' then
                    if type(StopTracking) == 'function' then
                        StopTracking()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(StartBloodTrack) == 'function' then
                    StartBloodTrack()
                end
            end,
        }
    end

    if Config.Features.GunpowderSniffing then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_track_gunpowder',
            label = locale('radial.track_gunpowder_label'),
            icon = 'crosshairs',
            onSelect = function()
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(GetActiveTrackType) == 'function' and GetActiveTrackType() == 'gunpowder' then
                    if type(StopTracking) == 'function' then
                        StopTracking()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(StartGunpowderTrack) == 'function' then
                    StartGunpowderTrack()
                end
            end,
        }
    end

    --- Bite & Hold / Release — DEVELOPER_REFERENCE.md §12.5.1. A single
    --- context-sensitive item, following the SAME toggle shape as Attach/Detach
    --- Leash above: client/combat.lua's RequestBiteHold()/ReleaseBiteHold()/
    --- IsBiteHoldEngaged() are a start/stop pair with an "am I engaged" query,
    --- exactly mirroring IsLeashed()-driven Attach/Detach — so this is written
    --- as ONE item, not two, per that established precedent (two separate
    --- always-visible "Bite & Hold" and "Release" entries would mean one of
    --- them is always a no-op click depending on current state, which is
    --- exactly the shape client/radial.lua's own Leash/Track items already
    --- rejected). Unlike Detach Leash (which skips the access gate entirely on
    --- the way out, since client/movement.lua's DetachLeash() itself never
    --- re-checks access), the Release branch here still re-checks CanShowK9UI()
    --- first: client/combat.lua's own header frames ReleaseBiteHold() as
    --- "always available while engaged" only with respect to the SERVER-side
    --- re-check (never re-validating HasK9Access/feature-flag on the way out),
    --- not as a client-side UI-gate exemption the way Detach Leash's own
    --- comment explicitly documents — so this keeps the same "gate every call
    --- into client/combat.lua" posture as every other item here rather than
    --- assume a client-side exemption client/combat.lua's own comment never
    --- actually claims for this specific function.
    ---
    --- STRUCTURE CHOICE — flat top-level item, NOT nested under a "Combat"
    --- submenu: unlike Bark's submenu (which nests because Config.
    --- AdvancedBarkRadial is a variable-length, config.lua-driven LIST of
    --- variants sharing one action), BiteAndHold is a single fixed action, and
    --- this menu already has a precedent for keeping multiple thematically-
    --- related-but-functionally-distinct fixed actions flat rather than
    --- grouping them: the three Track items above (Scent/Blood/Gunpowder) are
    --- exactly that shape and were deliberately NOT nested under a "Track"
    --- submenu. BiteAndHold/NonLethalTakedown below follow that same flat
    --- precedent, not Bark's nesting one. Config.Features.BiteAndHold gate
    --- (stays `false` by default — see config.lua).
    if Config.Features.BiteAndHold then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_bite_hold',
            label = locale('radial.bite_hold_toggle_label'),
            icon = 'paw',
            onSelect = function()
                -- Release is NOT gated on CanShowK9UI(), matching the Detach
                -- Leash branch above and DEVELOPER_REFERENCE.md §9 item 3b's "no unbounded
                -- trap" requirement. ReleaseBiteHold()'s own doc comment claims
                -- exactly this exemption ("always available while engaged, same
                -- no consent/access gate on the way out"), and server/combat.lua's
                -- releaseBiteHold handler never re-checks HasK9Access or the
                -- feature flag on the way out either -- only that this src is
                -- genuinely the holder.
                --
                -- Gating this would strand a K9 that loses access WHILE engaged
                -- (decertified mid-hold by a supervisor, model swap, or an
                -- operator flipping the feature flag): DenyK9UIAccess() would
                -- fire, the menu would refuse, and the hold would persist to the
                -- server's timeout with no way for the holder to let go. Mid-
                -- action revocation is a real path in this resource, not a
                -- hypothetical -- see server/search.lua's mid-flight
                -- HasK9Access re-check and certifications.lua's
                -- ForceDetachLeashForSource teardown on revoke.
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then
                    if type(ReleaseBiteHold) == 'function' then
                        ReleaseBiteHold()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                -- RequestBiteHold() itself finds the nearest eligible target and
                -- notifies "no eligible target in range" on failure — nothing
                -- further to do here, same "call straight through, no
                -- re-derived logic in this file" posture as Sit/Vehicle above.
                if type(RequestBiteHold) == 'function' then
                    RequestBiteHold()
                end
            end,
        }
    end

    --- Non-Lethal Takedown — DEVELOPER_REFERENCE.md §12.5.2. A single one-shot action
    --- item, NOT a context-sensitive toggle like Bite & Hold above:
    --- client/combat.lua exposes only RequestTakedown(), with no matching
    --- "release"/"cancel" counterpart and no IsTakedownEngaged()-style query —
    --- the forced ragdoll it triggers always ends on its own (server-driven
    --- EndHold on timeout, per client/combat.lua's own CLOCK-DOMAIN NOTE and
    --- DEFENSE IN DEPTH backstop), never by a second player action the way
    --- releasing a bite hold does. This mirrors Sit's shape (a single always-
    --- "go" action), not Leash/Bite & Hold's toggle shape, because the
    --- underlying capability itself has no second state to toggle back from.
    --- Kept flat (not nested), same "Track precedent over Bark precedent"
    --- reasoning as Bite & Hold above. Config.Features.NonLethalTakedown gate
    --- (stays `false` by default — see config.lua).
    if Config.Features.NonLethalTakedown then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_takedown',
            label = locale('radial.takedown_label'),
            icon = 'zzz',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                -- RequestTakedown() itself finds the nearest eligible target and
                -- notifies on failure; the server independently re-derives
                -- eligibility (e.g. the fleeing/speed gate) from live position
                -- samples regardless of anything this client claims — see
                -- client/combat.lua's own comment on RequestTakedown() for why
                -- no local "is the target fleeing" pre-check belongs here.
                -- type(...) == 'function' guard -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(RequestTakedown) == 'function' then
                    RequestTakedown()
                end
            end,
        }
    end

    --- Drag / Release — DEVELOPER_REFERENCE.md §12.5.4. A single context-sensitive item,
    --- the SAME toggle shape as Bite & Hold / Attach-Detach Leash above:
    --- client/combat.lua's RequestDrag()/ReleaseDrag()/IsDragEngaged() are a
    --- start/stop pair with an "am I engaged" query, exactly mirroring
    --- IsBiteHoldEngaged()-driven Bite & Hold — so this is one item, not two,
    --- for the same reason given there (two always-visible entries would mean
    --- one is always a no-op click depending on current state). Kept flat (not
    --- nested), same "Track precedent over Bark precedent" reasoning as Bite &
    --- Hold/Non-Lethal Takedown above. Config.Features.PropDragging gate (stays
    --- `false` by default — see config.lua).
    ---
    --- RELEASE ORDERING — do not gate this on CanShowK9UI(): same "no
    --- unbounded trap" requirement as Detach Leash and Bite & Hold's own
    --- Release branch above (DEVELOPER_REFERENCE.md §9 item 3b — see Bite & Hold's comment
    --- block above for the full reasoning, which applies here verbatim).
    --- client/combat.lua's ReleaseDrag() itself never re-checks
    --- HasK9Access/feature-flag on the way out either (only that this src is a
    --- legitimate party to the drag, holder or target) — gating this client-side
    --- check would strand a K9 that loses access mid-drag (decertified,
    --- feature-flag flip, model swap) with no way to let go, stranding the drag
    --- until the server's maxDragDurationMs timeout. This was the exact mistake
    --- corrected for Bite & Hold above; not repeating it here.
    if Config.Features.PropDragging then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_drag',
            label = locale('radial.drag_toggle_label'),
            icon = 'hand',
            onSelect = function()
                -- Release is NOT gated on CanShowK9UI() — see this item's
                -- header comment above ("RELEASE ORDERING") for why.
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup.
                if type(IsDragEngaged) == 'function' and IsDragEngaged() then
                    if type(ReleaseDrag) == 'function' then
                        ReleaseDrag()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                -- RequestDrag() itself finds the nearest eligible target and
                -- notifies "no eligible target in range" on failure — nothing
                -- further to do here, same "call straight through, no
                -- re-derived logic in this file" posture as Sit/Vehicle/Bite &
                -- Hold above.
                if type(RequestDrag) == 'function' then
                    RequestDrag()
                end
            end,
        }
    end

    --- Break Partnership -- DEVELOPER_REFERENCE.md §12.0 item 7. Closes a real gap:
    --- client/partnership.lua exposes BreakPartnership() as a fully
    --- implemented resource-global specifically FOR a future radial entry (see
    --- that file's own header, "FILE-TO-FILE CONTRACT" -> BreakPartnership()),
    --- but nothing in this resource called it -- "Partner Up" has a live
    --- ox_target entry point, "Break Partnership" had none at all. Two
    --- consenting players therefore had no way to end a partnership short of
    --- one of them losing certification or changing department (and even THAT
    --- teardown path is separately disclosed as not actually wired yet -- see
    --- client/partnership.lua's header, "SEPARATE, ALSO DISCLOSED FINDING").
    --- This item is that entry point.
    ---
    --- NOT GATED ON CanShowK9UI() -- same "no unbounded trap" requirement as
    --- Detach Leash / Release Bite & Hold / Release Drag above (DEVELOPER_REFERENCE.md §9 item
    --- 3b), now applied to a persistent, DB-backed relationship instead of a
    --- session-scoped one. client/partnership.lua's own BreakPartnership() is
    --- documented as deliberately ungated for exactly this reason (its header:
    --- "TERMINATION MUST NEVER BE GATED") -- gating the call HERE with a
    --- CanShowK9UI() check this file adds on top would silently reintroduce the
    --- exact trap that function was written to avoid (e.g. a K9 decertified or
    --- moved off-department while still partnered would hit DenyK9UIAccess()
    --- and have no way to leave). This onSelect therefore does nothing but the
    --- type-guarded call below -- no access check, no local state check, before
    --- or after.
    ---
    --- NOT A CONTEXT-SENSITIVE TOGGLE with "Partner Up" (unlike Attach/Detach
    --- Leash, Bite & Hold, and Drag above), even though client/partnership.lua's
    --- own header floats exactly that dual-mode shape as a possibility for
    --- "a future radial entry." Deliberately NOT done here: every one of this
    --- file's existing toggles keys its branch off a LOCAL client-side state
    --- query (IsLeashed(), IsBiteHoldEngaged(), IsDragEngaged()) that mirrors
    --- SERVER-side data the client can never fall meaningfully behind on --
    --- movement.lua's own header frames leash pairs as ephemeral, session-scoped
    --- state that cannot survive this client's own reconnect/restart, so a
    --- locally-nil leash state is always accurate. client/partnership.lua's
    --- PartnershipState cache has NO such guarantee: partnership.lua's own
    --- header ("KNOWN CACHE-STALENESS GAP") discloses that IsPartnered() CAN
    --- under-report for a client that reconnects, or whose OWN resource
    --- restarts, while genuinely still partnered per the DB -- nothing in
    --- server/partnership.lua's current contract re-syncs
    --- 'qbx_k9unit:client:partnershipEstablished' (or anything else) to a
    --- reconnecting client. If this item toggled visibility/label off
    --- IsPartnered() the way Leash/Bite & Hold/Drag toggle off their own local
    --- state, a genuinely-partnered player who just reconnected would read a
    --- stale `false`, see only "Partner Up" here (never "Break Partnership"),
    --- and get nothing but the server's `already_partnered` rejection if they
    --- tried it -- silently reintroducing the exact trap this item exists to
    --- close, and doing it specifically to the players most likely to hit it
    --- (anyone who reconnected mid-shift). So instead: a single, ALWAYS-OFFERED,
    --- flat action -- gated ONLY on Config.Features.HandlerPartnership at
    --- registration (same as every other item's own feature flag here), never
    --- on any client-side partnership-state read. This is safe to click even
    --- for a player who was never partnered at all: BreakPartnership() sends
    --- unconditionally, and server/partnership.lua's own breakPartnership
    --- handler is an already-safe no-op for that case (NotifyPlayer: "You are
    --- not currently partnered with anyone."). Offering this to a never-
    --- partnered player is a DELIBERATE tradeoff, not an oversight left to be
    --- "fixed" later -- a future reviewer who hides this behind an
    --- IsPartnered() check to avoid that redundant click would silently bring
    --- the reconnect trap back. An exit that is occasionally offered when
    --- unneeded is strictly better than one that is sometimes invisible to
    --- exactly the player who needs it.
    ---
    --- The live partnership-status callback this section once anticipated
    --- has since landed -- server/partnership.lua registers
    --- `lib.callback.register('qbx_k9unit:server:getPartnershipState', ...)`,
    --- returning current SERVER-truth partnership state, and
    --- client/partnership.lua's RefreshPartnershipStateFromServer() already
    --- awaits it (per this resource's own fxmanifest.lua comment on that
    --- file). This item needed no change when it landed -- "Break
    --- Partnership" stays unconditionally offered regardless of local
    --- partnership-state cache accuracy, for the exact reconnect-trap reason
    --- described above. Noted here so a future reader doesn't go looking for
    --- a callback that already exists.
    if Config.Features.HandlerPartnership then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_break_partnership',
            label = locale('radial.break_partnership_label'),
            icon = 'handshake-slash',
            onSelect = function()
                -- type(...) == 'function' guard per this codebase's established
                -- soft-dependency convention (e.g. RestoreInjury, AwardXP/
                -- GetXPTier) -- effectively always true here in practice, since
                -- this item is only ever registered under the SAME
                -- Config.Features.HandlerPartnership flag that gates
                -- client/partnership.lua's entire file (its own top-of-file
                -- `if not Config.Features.HandlerPartnership then return end`),
                -- so by the time a player can click this, that file has already
                -- run and defined BreakPartnership(). Kept anyway: client/
                -- partnership.lua's own header explicitly names this exact
                -- guard as what a future radial caller should use, and it costs
                -- nothing to honor that against, say, a future load-order change.
                if type(BreakPartnership) == 'function' then
                    BreakPartnership()
                end
            end,
        }
    end

    --- Partner Up -- DEVELOPER_REFERENCE.md §12.0 item 7. The other half of the gap
    --- Break Partnership above already closes: client/partnership.lua's own
    --- ox_target "Partner Up" option is a live entry point; this item is what
    --- makes fxmanifest.lua's comment on client/partnership.lua ("the radial
    --- entry is now wired") true from this file's side as well.
    ---
    --- A SEPARATE FLAT ITEM, NOT A DUAL-MODE TOGGLE WITH Break Partnership --
    --- same reasoning Break Partnership's own comment block above already
    --- gives IN FULL for why THIS FILE never keys a Partner-Up/Break-Partnership
    --- choice off IsPartnered() (see "KNOWN CACHE-STALENESS GAP", above).
    --- client/partnership.lua's own header does separately float
    --- RefreshPartnershipStateFromServer() as having been built "for... a
    --- dual-mode radial item that picks Partner Up vs Break Partnership" --
    --- deliberately NOT taken up here: Break Partnership's own resolution above
    --- already settled this file's position on that exact question (kept
    --- unconditional/flat even after that callback landed, specifically so the
    --- one control that always works is never hidden behind a state read that
    --- can be stale for a just-reconnected player), and introducing a SECOND,
    --- opposite-conclusion pattern for the mirror-image action in the same
    --- submenu would leave two contradictory answers to the identical design
    --- question sitting side by side. Two always-offered flat items (this one
    --- gated on CanShowK9UI() since it's an INITIATION, Break Partnership
    --- ungated since it's a TERMINATION -- see this file's header's general
    --- initiation-vs-termination gating split) give the same full coverage
    --- without that inconsistency: clicking Partner Up while already partnered
    --- just costs one harmless, already-tolerated round trip
    --- (RequestPartnerUp()'s own local IsPartnered() pre-check, or failing
    --- that server/partnership.lua's CheckPartnershipEligibility, rejects it
    --- with a clear notification either way -- the exact tolerance
    --- client/partnership.lua's own header already documents for its
    --- ox_target predicate's identical display-only imprecision).
    ---
    --- Candidate selection: FindNearestPartnerCandidate() above, this file's
    --- header.
    if Config.Features.HandlerPartnership then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_partner_up',
            -- Reuses the already-migrated partnership.* key rather than minting
            -- a fourth-pass-flagged duplicate — see DEVELOPER_REFERENCE.md's
            -- "Found, NOT touched" note on this exact label (byte-for-byte
            -- identical to client/partnership.lua's own ox_target option text).
            label = locale('partnership.partner_up_target_label'),
            icon = 'handshake',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                local candidateServerId = FindNearestPartnerCandidate()
                if not candidateServerId then
                    lib.notify({ title = locale('common.notify_title'), description = locale('radial.no_partner_candidate'), type = 'error' })
                    return
                end

                if type(RequestPartnerUp) == 'function' then
                    RequestPartnerUp(candidateServerId)
                end
            end,
        }
    end

    --- Recall -- DEVELOPER_REFERENCE.md §12.5.1. Closes a real gap: client/recall.lua
    --- exposes RequestRecall() specifically "ready for [a future
    --- client/radial.lua entry]" (that file's own header); this item is that
    --- entry, alongside client/recall.lua's own '/k9recall' chat command.
    --- config.lua's own Config.Recall header independently names this exact
    --- feature this resource's "PRIMARY TERMINATION" path.
    ---
    --- NOT GATED ON CanShowK9UI() -- same "no unbounded trap" requirement as
    --- Detach Leash / Release Bite & Hold / Release Drag / Break Partnership
    --- above (DEVELOPER_REFERENCE.md §9 item 3b). client/recall.lua's own header states this
    --- by name: "TERMINATION MUST NEVER BE GATED -- RequestRecall() below
    --- calls NEITHER CanShowK9UI() NOR DenyK9UIAccess()... Recall is a
    --- TERMINATION action, not an initiation." Gating the call HERE would
    --- reintroduce exactly the trap that function exists to avoid -- e.g. a
    --- handler who has lost K9 access (decertified, department change,
    --- feature-flag flip) while their partnered K9 is still engaged in a
    --- bite/takedown/drag would hit DenyK9UIAccess() and have no radial path
    --- to call their K9 off, left with only the raw '/k9recall' command (which
    --- deliberately carries no such gate either) to reach the one control this
    --- item exists to expose in the first place. Kept FLAT, not nested inside
    --- a submenu, on purpose -- this is meant to be reachable in the fewest
    --- possible clicks, the same reasoning every other release/termination
    --- item in this file is also kept flat rather than buried a level deeper.
    ---
    --- No local pre-check of any kind, before or after the type() guard --
    --- RequestRecall() itself performs none either, for the identical reason
    --- its own doc comment gives: "a stale local... read must never be able to
    --- withhold a request the server can otherwise correctly resolve."
    if Config.Features.Recall then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_recall',
            label = locale('radial.recall_label'),
            icon = 'circle-down',
            onSelect = function()
                if type(RequestRecall) == 'function' then
                    RequestRecall()
                end
            end,
        }
    end

    --- Handler-Down Defense confirm -- DEVELOPER_REFERENCE.md §12.5.3. Fixes a real
    --- WRONG-INSTRUCTION bug: client/defense.lua's own
    --- handlerDownDefenseTrigger notify literally tells the K9 "Press %s to
    --- respond, OR USE THE RADIAL MENU" -- this item is what makes that
    --- instruction true; without it, no radial menu entry for this action
    --- existed anywhere in this file.
    ---
    --- A SUBMENU OF TWO TERMINAL ACTIONS, NOT ONE ITEM -- unlike this
    --- feature's own keybind (which always confirms 'bite' by default, per
    --- ConfirmHandlerDownDefense()'s own doc comment: "Bite-and-hold is chosen
    --- as the default here... ConfirmHandlerDownDefense('takedown') remains
    --- fully available for a future radial/second-keybind entry that wants it
    --- explicitly"), the radial is exactly the surface that CAN offer the
    --- explicit choice a single keypress can't -- so both actionType values
    --- are exposed here. Nested (mirroring Bark's submenu precedent, not
    --- Track's flat one) because these are two distinct terminal actions
    --- sharing the SAME one pending prompt, not a context-sensitive toggle
    --- between two states of one ongoing thing -- clicking either one consumes
    --- the prompt outright (ConfirmHandlerDownDefense()'s own doc comment:
    --- "a second press without a fresh trigger falls through to 'no active
    --- alert'"), so there's no toggle shape to collapse them into the way
    --- Bite & Hold/Drag collapse their own start/stop pairs into one item.
    ---
    --- NEITHER sub-item skips CanShowK9UI() -- this is an INITIATION action
    --- (starts a bite/takedown request against a suggested hostile), never a
    --- release/termination, so the "no unbounded trap" exemption Recall/Break
    --- Partnership/the various Release branches rely on above does not apply
    --- here. This mirrors ConfirmHandlerDownDefense()'s own internal
    --- CanShowK9UI()/DenyK9UIAccess() gate -- this file's redundant pre-check
    --- here follows the same "check here too, even though the callee already
    --- checks" posture every other gated item in this file already uses.
    if Config.Features.HandlerDownDefense then
        lib.registerRadial({
            id = 'k9unit_defense',
            items = {
                {
                    id = 'k9_defense_bite',
                    label = locale('radial.defense_bite_label'),
                    icon = 'paw',
                    onSelect = function()
                        if not CanShowK9UI() then
                            DenyK9UIAccess()
                            return
                        end

                        if type(ConfirmHandlerDownDefense) == 'function' then
                            ConfirmHandlerDownDefense('bite')
                        end
                    end,
                },
                {
                    id = 'k9_defense_takedown',
                    label = locale('radial.defense_takedown_label'),
                    icon = 'zzz',
                    onSelect = function()
                        if not CanShowK9UI() then
                            DenyK9UIAccess()
                            return
                        end

                        if type(ConfirmHandlerDownDefense) == 'function' then
                            ConfirmHandlerDownDefense('takedown')
                        end
                    end,
                },
            },
        })

        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_defense',
            label = locale('radial.defense_menu_label'),
            icon = 'user-shield',
            menu = 'k9unit_defense',
        }
    end

    --- Fetch -- Phase 5 (FetchMechanic). client/fetch.lua exposes
    --- RequestThrowFetchBall()/ReleaseFetchBall()/RequestRecallFetchBall()/
    --- IsFetchCarryEngaged() specifically for a client/radial.lua entry to
    --- call (that file's own header); this submenu is that entry point.
    --- "Pick Up Ball" and "Deliver to Handler" stay ox_target options exactly
    --- as client/fetch.lua's own header already documents (targeted,
    --- proximity-driven actions on a specific ball/player, not a
    --- self-initiated radial verb) -- not duplicated here.
    ---
    --- TWO ITEMS, NOT THREE, DESPITE THREE UNDERLYING FUNCTIONS -- Throw and
    --- Release are combined into ONE context-sensitive toggle (same shape as
    --- Attach/Detach Leash / Bite & Hold / Drag above: IsFetchCarryEngaged()
    --- plays the same role IsLeashed()/IsBiteHoldEngaged()/IsDragEngaged() do),
    --- since they are true opposites of the SAME per-client carry state, never
    --- offered simultaneously. Recall stays a SEPARATE item because it is NOT
    --- that state's opposite -- client/fetch.lua's own doc comment frames it as
    --- "the THROWER's own early-interrupt for their currently active fetch
    --- cycle (any state)," i.e. it belongs to the client who threw the ball,
    --- who is typically NOT the client currently carrying it (the normal case
    --- immediately after a throw, before any K9 has picked it up). Folding
    --- Recall into the same toggle would mean a thrower who isn't the current
    --- carrier -- the common case -- could never reach it, since
    --- IsFetchCarryEngaged() would read false on their own client and route
    --- them into "Throw" instead, silently losing the one control that lets
    --- them call off a cycle they started.
    ---
    --- GATING: the Throw branch checks HasK9Access() directly (NOT
    --- CanShowK9UI()) -- matching RequestThrowFetchBall()'s own doc comment
    --- verbatim: "a HUMAN HANDLER action (gated on HasK9Access() alone, NOT
    --- CanShowK9UI()/IsOwnModelK9() ... the thrower need not currently be
    --- riding a K9 model)." Using CanShowK9UI() here instead would additionally
    --- require IsOwnModelK9(), silently blocking the exact human-handler-not-
    --- currently-a-K9 use case this feature exists for. The Release branch and
    --- Recall are NOT gated at all -- same "no unbounded trap" reasoning as
    --- every other release/termination item above; client/fetch.lua's own doc
    --- comments state this explicitly for both ("Always available while
    --- carrying -- no access gate on the way out" / "deliberately NOT gated on
    --- HasK9Access()/CanShowK9UI() ... must still be able to call it off").
    if Config.Features.FetchMechanic then
        lib.registerRadial({
            id = 'k9unit_fetch',
            items = {
                {
                    id = 'k9_fetch_throw',
                    label = locale('radial.fetch_throw_label'),
                    icon = 'baseball',
                    onSelect = function()
                        if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then
                            if type(ReleaseFetchBall) == 'function' then
                                ReleaseFetchBall()
                            end
                            return
                        end

                        if not HasK9Access() then
                            DenyK9UIAccess()
                            return
                        end

                        if type(RequestThrowFetchBall) == 'function' then
                            RequestThrowFetchBall()
                        end
                    end,
                },
                {
                    id = 'k9_fetch_recall',
                    label = locale('radial.fetch_recall_label'),
                    icon = 'circle-down',
                    onSelect = function()
                        if type(RequestRecallFetchBall) == 'function' then
                            RequestRecallFetchBall()
                        end
                    end,
                },
            },
        })

        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_fetch',
            label = locale('radial.fetch_menu_label'),
            icon = 'baseball',
            menu = 'k9unit_fetch',
        }
    end

    --- Toggle K9 Vest -- Phase 5 R&D (PropAttachments). Closes a real gap:
    --- client/propattachment.lua exposes RequestToggleK9PropAttachment()
    --- specifically "so a future radial entry can call this directly without
    --- this file needing to change" (that function's own doc comment); this
    --- item is that entry point, alongside the existing '/k9propattach'
    --- command.
    ---
    --- A SINGLE FLAT TOGGLE ITEM, not two -- RequestToggleK9PropAttachment()
    --- is already a toggle by design (its own doc comment: "a toggle is a
    --- single request whose MEANING (add vs remove) is decided server-side by
    --- whether PropAttachmentState already has an entry"), so this item does
    --- NOT attempt to locally track "do I currently have a vest on" the way
    --- IsLeashed()/IsBiteHoldEngaged()/IsDragEngaged()/IsFetchCarryEngaged()
    --- key their own toggles -- there is no equivalent client-exposed query to
    --- read here, and the underlying function does not need one either: it
    --- always sends, and the server decides what that means.
    ---
    --- GATED ON CanShowK9UI() here too, even though
    --- RequestToggleK9PropAttachment() already re-checks it (and
    --- Config.Features.PropAttachments itself) internally -- same redundant
    --- "check here too, even though the callee already checks" posture every
    --- other gated item in this file already uses.
    if Config.Features.PropAttachments then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_prop_attachment',
            label = locale('radial.toggle_vest_label'),
            icon = 'vest',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(RequestToggleK9PropAttachment) == 'function' then
                    RequestToggleK9PropAttachment()
                end
            end,
        }
    end

    --- Deploy Kennel -- Phase 5 R&D (DeployableKennel). Closes a real gap:
    --- client/kennel.lua exposes RequestDeployKennel() specifically "so a
    --- future radial item can call it directly once client/radial.lua is
    --- available to extend again" (that function's own doc comment); this item
    --- is that entry point, alongside the existing '/k9deploykennel' command.
    ---
    --- DEPLOY-ONLY, BY DESIGN, NOT A DISCLOSED OMISSION -- "Pick Up Kennel"
    --- stays client/kennel.lua's own established ox_target option on the
    --- physical prop (its own header names that as the entry point for that
    --- half); there is no location-independent "recall my kennel" global
    --- exposed anywhere in this resource to mirror here (unlike Fetch's
    --- RequestRecallFetchBall() above), so this item has no release/recall
    --- counterpart to add alongside it.
    ---
    --- GATED ON CanShowK9UI() here too, even though RequestDeployKennel()
    --- already re-checks it (and Config.Features.DeployableKennel, and its own
    --- "already have one deployed" local short-circuit) internally -- same
    --- redundant "check here too, even though the callee already checks"
    --- posture every other gated item in this file already uses.
    if Config.Features.DeployableKennel then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_deploy_kennel',
            label = locale('radial.deploy_kennel_label'),
            icon = 'house-chimney',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(RequestDeployKennel) == 'function' then
                    RequestDeployKennel()
                end
            end,
        }
    end

    --- Open My Gear -- Phase 4 (K9Inventory). Closes a real gap: client/inventory.lua
    --- exposes RequestOpenOwnK9Inventory() specifically as a "future
    --- client/radial.lua 'Open My Gear' item" entry point (see that file's own
    --- header, "RESOLVED" note); this item is that entry point -- the only
    --- other live entry point into a K9 player's own gear stash is the
    --- ox_target "Open K9 Gear" option on their own ped, awkward/unusual UX
    --- for targeting yourself (that file's own header names this exact
    --- awkwardness as the reason a self-service global was added).
    ---
    --- `RequestOpenOwnK9Inventory()` takes no arguments and re-checks both
    --- CanShowK9UI() and Config.Features.K9Inventory internally (confirmed by
    --- reading client/inventory.lua directly, not assumed) -- this item's own
    --- CanShowK9UI() gate below is therefore redundant with the callee, same
    --- "check here too, even though the callee already checks" posture every
    --- other gated item in this file already uses (Toggle K9 Vest/Deploy Kennel
    --- immediately above are the closest precedent: both call a self-contained,
    --- already-gated global the exact same way). This is an INITIATION action
    --- (opens a stash against the local player's own ped), not a
    --- release/termination one, so the "no unbounded trap" exemption given to
    --- Detach Leash/Recall/etc. above does not apply here.
    if Config.Features.K9Inventory then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_open_inventory',
            label = locale('radial.open_inventory_label'),
            icon = 'briefcase',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(RequestOpenOwnK9Inventory) == 'function' then
                    RequestOpenOwnK9Inventory()
                end
            end,
        }
    end

    --- Treat K9 -- Phase 4 (K9Medkit). Closes a real gap: client/medkit.lua
    --- exposes RequestTreatNearestK9() specifically as a radial entry point
    --- (see that file's own header, "FILE-TO-FILE CONTRACT" -> "THIS FILE
    --- exposes one resource-global function for a radial entry point"); this
    --- item is that entry point -- the only other live entry point into the
    --- treat-request sequence is the ox_target "Treat K9" option on a
    --- specifically-targeted K9 player, leaving a handler with no visible
    --- nearby K9 (or who simply prefers the radial) no way to self-initiate the
    --- same request against the nearest eligible K9.
    ---
    --- Label reuses `medkit.treat_target_label` ("Treat K9") rather than
    --- minting a byte-identical second key -- same "reuse an existing key
    --- when the English matches exactly" convention this file already applies
    --- to Partner Up's `partnership.partner_up_target_label` and the opener's
    --- `${common.notify_title}` cross-reference (see this file's own header /
    --- DEVELOPER_REFERENCE.md).
    ---
    --- `RequestTreatNearestK9()` takes no arguments and re-checks both
    --- CanShowK9UI() and Config.Features.K9Medkit internally (confirmed by
    --- reading client/medkit.lua directly, not assumed) -- this item's own
    --- CanShowK9UI() gate below is therefore redundant with the callee, same
    --- posture as Open My Gear immediately above. This is an INITIATION action
    --- (starts a treat request against a found target), not a
    --- release/termination one, so the "no unbounded trap" exemption given to
    --- Detach Leash/Recall/etc. above does not apply here.
    if Config.Features.K9Medkit then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_treat_nearest',
            label = locale('medkit.treat_target_label'),
            icon = 'kit-medical',
            onSelect = function()
                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(RequestTreatNearestK9) == 'function' then
                    RequestTreatNearestK9()
                end
            end,
        }
    end

    --- Search & Rescue Call -- closes a real gap: client/sarcalls.lua's
    --- RequestStartSarCall()/RequestAbandonSarCall() previously had no
    --- client/radial.lua entry point; until now this feature was reachable
    --- ONLY via '/k9sarcall [stop]' -- exactly the "reachable only by
    --- remembering an exact command" shape this resource's own radial menu
    --- exists to avoid.
    ---
    --- A single context-sensitive toggle item, the SAME shape as
    --- Attach/Detach Leash / Bite & Hold / Drag / Fetch above:
    --- IsSarCallActive() (client/sarcalls.lua, added specifically for this)
    --- plays the same role IsLeashed()/IsBiteHoldEngaged()/IsDragEngaged()/
    --- IsFetchCarryEngaged() do for those toggles -- a pure, no-network
    --- local-state read, never itself a gate.
    ---
    --- Abandon branch is NOT gated on CanShowK9UI() -- same "no unbounded
    --- trap" requirement as every other release/termination branch above.
    --- RequestAbandonSarCall()'s own doc comment states this explicitly:
    --- "UNCONDITIONAL, never gated... a player who loses access, or simply
    --- wants to give up, must always be able to abandon a call." The Start
    --- branch keeps the same redundant "check here too, even though the
    --- callee already checks" CanShowK9UI() posture every other initiation
    --- item in this file uses (RequestStartSarCall() re-checks it again
    --- internally regardless).
    if Config.Features.SARCalls then
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_sar_call',
            label = locale('radial.sar_call_toggle_label'),
            icon = 'life-ring',
            onSelect = function()
                -- type(...) == 'function' guards -- see k9_sit's identical
                -- note above for the full HEADER/CODE DRIFT FIX writeup. An
                -- absent IsSarCallActive() is treated as "no call active"
                -- (falls through to the Start branch).
                if type(IsSarCallActive) == 'function' and IsSarCallActive() then
                    if type(RequestAbandonSarCall) == 'function' then
                        RequestAbandonSarCall()
                    end
                    return
                end

                if not CanShowK9UI() then
                    DenyK9UIAccess()
                    return
                end

                if type(RequestStartSarCall) == 'function' then
                    RequestStartSarCall()
                end
            end,
        }
    end

    --- Training -- closes a real gap: Training Mode and its two practice
    --- drills were previously reachable ONLY via '/k9training <on|off>',
    --- '/k9trainsearch' and '/k9trainbite' -- exactly the "reachable only by
    --- remembering an exact command" shape this resource's own radial menu
    --- exists to avoid, and worse than most: '/k9training' with NO argument
    --- (the single most natural first thing to type) produces only a usage
    --- error, never a toggle. See client/training.lua's own header "RADIAL
    --- ENTRY POINT" section for the full contract of the three globals this
    --- nested submenu calls.
    ---
    --- NESTED, mirroring Bark / Handler-Down Response / Fetch's own submenu
    --- precedent (several related terminal actions sharing one theme), not
    --- Track's flat precedent (independent, mutually exclusive actions).
    ---
    --- Start/Stop Training is a single context-sensitive toggle, same shape
    --- as every other toggle in this file -- IsTrainingModeActive() plays
    --- the same role IsLeashed()/IsSarCallActive() do. The Stop branch is
    --- NOT gated on CanShowK9UI() -- same "no unbounded trap" reasoning as
    --- every other release/termination branch above; server/training.lua's
    --- own OFF branch is itself unconditional to match. The Start branch
    --- checks HasK9Access() directly, NOT CanShowK9UI() -- mirrors the
    --- Fetch "Throw" branch's own identical choice above verbatim:
    --- server/training.lua's setTrainingMode handler checks HasK9Access(src)
    --- plus a per-person feature grant, never a ped-model check, so this is
    --- a human-handler action, not a "must currently be riding a K9" one --
    --- using the stricter CanShowK9UI() combinator here would refuse an
    --- otherwise-eligible handler simply for not being on a K9 model right
    --- now.
    ---
    --- The two drill items below carry NO CanShowK9UI()/HasK9Access() gate
    --- of their own -- RequestTrainingSearchDrill()/RequestTrainingBiteDrill()
    --- themselves only ever check the local `trainingModeActive` flag
    --- (client/training.lua's RunTrainingDrill, unmodified), and adding an
    --- access gate here that the command path never had would make the
    --- radial and the command behave DIFFERENTLY for the identical action --
    --- see client/training.lua's own header for why this stays deliberately
    --- symmetric instead.
    if Config.Features.TrainingMode then
        lib.registerRadial({
            id = 'k9unit_training',
            items = {
                {
                    id = 'k9_training_toggle',
                    label = locale('radial.training_toggle_label'),
                    icon = 'graduation-cap',
                    onSelect = function()
                        -- type(...) == 'function' guards -- see k9_sit's
                        -- identical note above for the full HEADER/CODE
                        -- DRIFT FIX writeup. An absent IsTrainingModeActive()
                        -- is treated as "not currently training" (falls
                        -- through to the Start branch).
                        if type(IsTrainingModeActive) == 'function' and IsTrainingModeActive() then
                            if type(RequestSetTrainingMode) == 'function' then
                                RequestSetTrainingMode(false)
                            end
                            return
                        end

                        if not HasK9Access() then
                            DenyK9UIAccess()
                            return
                        end

                        if type(RequestSetTrainingMode) == 'function' then
                            RequestSetTrainingMode(true)
                        end
                    end,
                },
                {
                    id = 'k9_training_search',
                    label = locale('radial.training_search_label'),
                    icon = 'magnifying-glass',
                    onSelect = function()
                        if type(RequestTrainingSearchDrill) == 'function' then
                            RequestTrainingSearchDrill()
                        end
                    end,
                },
                {
                    id = 'k9_training_bite',
                    label = locale('radial.training_bite_label'),
                    icon = 'paw',
                    onSelect = function()
                        if type(RequestTrainingBiteDrill) == 'function' then
                            RequestTrainingBiteDrill()
                        end
                    end,
                },
            },
        })

        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_training',
            label = locale('radial.training_menu_label'),
            icon = 'graduation-cap',
            menu = 'k9unit_training',
        }
    end

    -- Per-person block on the WHOLE radial surface -- see this function's
    -- own "K9 UNIT RADIAL -- PER-PERSON BLOCK" header above.
    if Config.Features.RadialMenu then
        local radialMenuBlocked = IsRadialFeatureBlockedForMe('RadialMenu')

        -- The 'k9unit' submenu contents are only worth registering when
        -- reachable at all -- an orphaned-but-populated submenu while
        -- blocked is harmless (same disclosed nuance the GLOBAL
        -- RadialMenu=false path already has -- nothing links to it), but
        -- there is no reason to pay for it either.
        if not radialMenuBlocked then
            lib.registerRadial({
                id = 'k9unit',
                items = k9SubmenuItems,
            })
        end

        -- The ROOT OPENER, unlike the submenu above, is ALWAYS
        -- (re-)registered, every single time -- REPLACED in place, never
        -- removed. THIS IS DELIBERATE, not the "icon simply disappears"
        -- ideal this header's own design writeup would otherwise prefer:
        -- ox_lib's real, VERIFIED (see "DUPLICATE-VS-REPLACE" above)
        -- capability is REGISTER/REPLACE-by-id for `lib.addRadialItem` --
        -- there is no correspondingly VERIFIED removal call this codebase
        -- has confirmed against ox_lib's own source (a prior draft of this
        -- file's header floated `lib.removeRadialItem` as a hypothetical
        -- OPTION, never confirmed real -- see that history), and this
        -- resource's own established discipline is to never call an
        -- unverified native/API function on an assumption. So: BLOCKED
        -- swaps the SAME id's `onSelect`/`menu` fields (still a REPLACE,
        -- still fully within the verified contract) to a stub that
        -- explains why, rather than navigating anywhere -- the icon stays
        -- visible, but is honest and inert, never silently doing nothing.
        -- If `lib.removeRadialItem` is ever confirmed real (ask
        -- native-api-assistant), this is the one spot to revisit for the
        -- fully-honest "icon vanishes" behavior this design would prefer.
        if radialMenuBlocked then
            lib.addRadialItem({
                {
                    id = 'k9unit_open',
                    label = locale('radial.menu_open_label'),
                    icon = 'dog',
                    onSelect = function()
                        if type(DenyK9FeatureBlocked) == 'function' then DenyK9FeatureBlocked() end
                    end,
                },
            })
        else
            lib.addRadialItem({
                {
                    id = 'k9unit_open',
                    -- '${common.notify_title}' — ox_lib's own cross-reference
                    -- syntax (resolved once at lib.locale() load time), not a
                    -- coincidence: this opener's label and every lib.notify title
                    -- in this resource are the same "K9 Unit" string, so this
                    -- embeds that existing key rather than minting a byte-identical
                    -- duplicate under a different name (see DEVELOPER_REFERENCE.md).
                    label = locale('radial.menu_open_label'),
                    icon = 'dog',
                    menu = 'k9unit',
                },
            })
        end
    end
end

-- First call site for RegisterK9RadialMenu() -- this resource's own start,
-- or ox_lib's, same two-branch `onResourceStart` idiom as
-- client/movement.lua's RegisterLeashOxTargetOption() /
-- RegisterCertifyOxTargetOptions() / RegisterDoorInteractionOxTargetOptions(),
-- client/fetch.lua's RegisterFetchOxTargetOptions(), client/medkit.lua's and
-- client/wellbeing.lua's own matching dispatchers, and client/search.lua's --
-- all fixing the identical bug class against ox_target's own file-local
-- registries. Pointed at 'ox_lib' here instead of 'ox_target' since it's
-- ox_lib's `menus`/`menuItems` tables this file's own registrations live
-- inside -- see RegisterK9RadialMenu()'s own header comment above for the
-- full writeup of why that restart silently wipes this resource's entire
-- radial menu with no error, and why this dispatcher is the fix.
AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == 'ox_lib' then
        RegisterK9RadialMenu()
    end
end)

-- SECOND call site (client/featureblocks.lua -- see this function's own "K9
-- UNIT RADIAL -- PER-PERSON BLOCK" header above for the full contract). A
-- purely LOCAL event (client/featureblocks.lua's own TriggerEvent, never a
-- server round trip from here) fired every time this client processes a
-- fresh block-state sync -- re-running RegisterK9RadialMenu() here is what
-- makes a live RadialMenu/AdvancedBarkRadial block/unblock take effect
-- without waiting for either this resource or ox_lib to restart. Safe to
-- call this often (a rare event in practice -- join, reconnect, or a
-- high-command block action) because every registration inside
-- RegisterK9RadialMenu() REPLACES the previous one in place rather than
-- duplicating it -- see that function's own "DUPLICATE-VS-REPLACE" note.
AddEventHandler('qbx_k9unit:client:featureBlocksApplied', function()
    RegisterK9RadialMenu()
end)
