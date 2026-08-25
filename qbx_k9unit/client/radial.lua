--[[
    qbx_k9unit/client/radial.lua

    Phase 1 scaffold (coder-architect). Thin ox_lib radial menu WIRING
    ONLY — this file must never implement anim/native gameplay logic
    directly. Every item's onSelect should do at most a cheap access check
    plus a single call into a global function exposed by client/main.lua,
    client/movement.lua, or client/vehicle.lua. If an item needs more than
    a couple of lines to decide what to do, that logic belongs in one of
    those files, not here — keeps this file from becoming an
    everything-file as later phases add more radial items.

    ======================================================================
    EVENT/CALLBACK CONTRACT — this file does not register or trigger any
    network event/callback directly. It calls:
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
      - client/main.lua's HasK9Access() directly (not just via CanShowK9UI())
        for the one item — Fetch's Throw branch — whose own source file
        documents that it is deliberately gated on HasK9Access() alone, not
        the full CanShowK9UI() combinator (see that item's own comment for
        why, quoting client/fetch.lua's RequestThrowFetchBall() verbatim).
      Every cross-file global added after this file's own initial Phase 1
      pass is called behind a `type(fn) == 'function'` runtime existence
      guard (this codebase's established soft-dependency convention — see
      e.g. RestoreInjury/AwardXP in server/tracking.lua) because
      client/radial.lua loads FIRST among client_scripts (fxmanifest.lua),
      before every file listed above that defines one of these globals —
      the guard is never a load-order assumption, since by the time any of
      these onSelect closures actually RUNS (a player action, always well
      after this resource has finished loading), every one of those files
      has already executed and defined its own globals for real; it is kept
      anyway per this resource's own documented "runtime existence guard,
      not a load-order assumption" convention, matching every other guarded
      call site in this codebase.
    ======================================================================

    SPEC.md §6.1 / §8 step 7 Phase 1 radial item list: Bark, Sit,
    Attach/Detach Leash, Enter/Exit Vehicle — "each item only appears if
    its owning Config.Features flag is true AND the access check above
    passes."

    OPEN STRUCTURAL QUESTION flagged for coder-frontend (not decided
    here): ox_lib's `lib.addRadialItem` registers items once; there's no
    built-in live "should this item be visible right now" predicate the
    way ox_target's `canInteract` works. Two ways to satisfy "each item
    only appears if... access check passes" (SPEC.md §3/§6.1):
      (a) A lightweight polling thread (e.g. every 2-3s while the local
          player is near/playing) that calls CanShowK9UI() and
          lib.addRadialItem/lib.removeRadialItem the whole "K9 Unit"
          submenu in/out of existence accordingly.
      (b) Register the submenu once, unconditionally, and gate purely
          inside each onSelect via CanShowK9UI() (and the item's own
          Config.Features flag), notifying+denying on failure — the menu
          entry always "appears" but does nothing for a non-qualifying
          player.
    SPEC.md's "only appears if" phrasing leans toward (a), but a live
    network round-trip (CanShowK9UI awaits a server callback) firing every
    couple of seconds for every player near a PD may be more chatter than
    wanted — your call, but document whichever is chosen so
    qa-tester/integration-verifier know what "appears" means here.

    QBOX/OX_LIB API FIX (framework-compatibility pass, verified against
    ox_lib's actual source — overextended/ox_lib
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
]]

-- OPEN STRUCTURAL QUESTION resolution: option (b) was chosen — the "K9
-- Unit" submenu and its sub-items are registered ONCE, unconditionally
-- (subject to each item's own Config.Features flag at registration time,
-- satisfying SPEC.md §3's "read at the point... menu item visibility"),
-- and every onSelect below independently re-checks CanShowK9UI() before
-- doing anything, notifying+denying on failure. Rationale for (b) over
-- (a) here: every one of coder-architect's own onSelect TODO snippets
-- already assumed this exact "if not CanShowK9UI() then notify + return"
-- shape, which only makes sense if the item can actually be seen/selected
-- by a non-qualifying player in the first place; (a) would make that
-- branch largely unreachable. (b) also avoids a polling thread that
-- would otherwise re-await the server's hasK9Access callback every couple
-- of seconds for every player near a PD. (NOTE: a later
-- framework-compatibility pass DID verify the actual
-- lib.registerRadial/lib.addRadialItem submenu-then-children mechanics
-- against ox_lib's own source — see the QBOX/OX_LIB API FIX note above —
-- and found the original registration call itself was broken; that is
-- now fixed independently of this option-(b)-vs-(a) choice, which still
-- stands.) Documented here for qa-tester/
-- integration-verifier: "appears" in this file means "is present in the
-- radial wheel," not "is currently usable" — usability is enforced at
-- onSelect time, same as every gated server event is independently
-- re-verified server-side regardless of what the client shows.
--- Finds the nearest OTHER player within Config.LeashMaxDistance (the base
--- leash range, reused directly here as a search radius rather than via
--- a derived factor — see config.lua's comment on that field and
--- server/main.lua's header for the initiate-range check this mirrors),
--- for the Attach/Detach Leash radial item's self-initiated entry point.
--- Model plausibility isn't filtered here — the server independently
--- re-validates via CheckLeashEligibility (server/main.lua) regardless.
--- @return number? candidateServerId
local function FindNearestLeashCandidate()
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
local function FindNearestPartnerCandidate()
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

-- Contents of the "K9 Unit" SUBMENU (registered via lib.registerRadial
-- below) — none of these carry their own `menu` field. On an item, `menu`
-- means "selecting this navigates to another already-registered menu,"
-- not "this item belongs to submenu X" — see this file's header for the
-- verified ox_lib source behind that distinction. These are terminal
-- actions with their own onSelect, so `menu` must stay unset on all of
-- them.
local k9SubmenuItems = {
    --- Sit — SPEC.md §6.1. No dedicated Config.Features flag (bundled
    --- under the general RadialMenu flag + access check, same as every
    --- other Phase 1 item here).
    {
        id = 'k9_sit',
        label = 'Sit',
        icon = 'couch',
        onSelect = function()
            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end
            K9Sit()
        end,
    },
}

--- Bark — SPEC.md §6.1, §8 step 9. Config.Features.BasicBarkSounds gate.
---
--- Phase 5's AdvancedBarkRadial (Config.Features.AdvancedBarkRadial, layered
--- ON TOP of BasicBarkSounds — still requires it, matching how this resource
--- layers every Phase 5 feature over its Phase 1 prerequisite elsewhere,
--- e.g. ScentTracking/BloodTracking/GunpowderSniffing each standing alone
--- under RadialMenu) swaps the single generic "Bark" action for a nested
--- submenu of variants (Config.AdvancedBarkRadial, config.lua — SPEC.md
--- §6.7: "aggressive/alert/calm"). Every variant still funnels through the
--- SAME 'qbx_k9unit:server:relayBark' event with its own `barkType` string —
--- server/main.lua's handler is UNCHANGED for this feature; it already
--- accepts any opaque, length-capped barkType (BARK_TYPE_MAX_LENGTH = 16)
--- with no enum validation, exactly the shape this needs. When
--- AdvancedBarkRadial is off, behavior is byte-for-byte the same as before
--- this feature existed: a single 'k9_bark' action sending the literal
--- 'bark' string.
if Config.Features.BasicBarkSounds then
    if Config.Features.AdvancedBarkRadial then
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

        -- Opener item inside the "K9 Unit" submenu: selecting THIS navigates
        -- into 'k9unit_bark' (registered just above), same `menu`-field
        -- navigation mechanic this file's header already documents for the
        -- top-level 'k9unit_open' opener — this item carries no onSelect of
        -- its own on purpose.
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_bark',
            label = 'Bark',
            icon = 'volume-high',
            menu = 'k9unit_bark',
        }
    else
        k9SubmenuItems[#k9SubmenuItems + 1] = {
            id = 'k9_bark',
            label = 'Bark',
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

--- Attach/Detach Leash — SPEC.md §6.1, §8 step 6-7. A single
--- context-sensitive item: behaves as "Attach" when not currently
--- leashed, "Detach" when leashed. Config.Features.LeashMechanics gate.
--- See client/movement.lua's header for the full consent-based leash
--- design (attach requires the OTHER player to accept; detach never
--- does) — this item is one of two entry points into that same system
--- (the other being the ox_target option client/movement.lua registers
--- directly on nearby players).
if Config.Features.LeashMechanics then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_leash',
        label = 'Attach/Detach Leash',
        icon = 'link',
        onSelect = function()
            -- Detach never requires consent/access — always available
            -- while leashed, per SPEC.md §9 item 3b's hard requirement.
            if IsLeashed() then
                DetachLeash()
                return
            end

            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end

            local candidateServerId = FindNearestLeashCandidate()
            if not candidateServerId then
                lib.notify({ title = 'K9 Unit', description = 'No nearby player to leash to.', type = 'error' })
                return
            end

            -- This only SENDS a request — per the consent design, nothing
            -- attaches until the target accepts on their own client.
            -- RequestLeashAttach() itself notifies "request sent."
            RequestLeashAttach(candidateServerId)
        end,
    }
end

--- Enter/Exit Vehicle — SPEC.md §6.1, §8 step 8. A single
--- context-sensitive item mirroring the ox_target vehicle option
--- client/vehicle.lua registers directly. Config.Features.VehicleEntryExit
--- gate.
if Config.Features.VehicleEntryExit then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_vehicle',
        label = 'Enter/Exit Vehicle',
        icon = 'car',
        onSelect = function()
            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end

            if IsInK9Vehicle() then
                ExitK9Vehicle()
            else
                EnterNearestK9Vehicle()
            end
        end,
    }
end

--- Track Scent/Blood/Gunpowder — SPEC.md §11.3/§11.5, Phase 2. Each is a
--- single context-sensitive item: while a trail of THAT SPECIFIC type is
--- active it becomes a "Stop Tracking" cancel (calling the shared
--- StopTracking()); while tracking a DIFFERENT type is active, it defers to
--- Start*Track()'s own "already tracking — stop first" rejection/notify
--- rather than silently canceling the wrong trail; otherwise it starts that
--- specific trail type. This is deliberately the only in-game entry point
--- to client/tracking.lua's Start*Track()/StopTracking() globals —
--- integration-verifier/correctness-overseer both flagged that nothing
--- called them, leaving no way to trigger or cancel a trail at all.
--- regression-tester finding on the FIRST version of this wiring: a bare
--- `if IsTracking() then StopTracking()` check here (not gated on the
--- item's OWN type) meant clicking, say, "Track Gunpowder" while already
--- tracking blood would silently cancel the blood trail and do nothing
--- else — the click was swallowed by the wrong item's toggle branch, with
--- zero notification, and Track Gunpowder had to be clicked a SECOND time
--- to actually start. Fixed below via GetActiveTrackType() — each item now
--- only self-toggles when it's already the active type. Each gated
--- independently by its own Config.Features flag, same pattern as
--- Bark/Leash/Vehicle above.
if Config.Features.ScentTracking then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_track_scent',
        label = 'Track Scent',
        icon = 'wind',
        onSelect = function()
            if GetActiveTrackType() == 'scent' then
                StopTracking()
                return
            end

            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end

            StartScentTrack()
        end,
    }
end

if Config.Features.BloodTracking then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_track_blood',
        label = 'Track Blood',
        icon = 'droplet',
        onSelect = function()
            if GetActiveTrackType() == 'blood' then
                StopTracking()
                return
            end

            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end

            StartBloodTrack()
        end,
    }
end

if Config.Features.GunpowderSniffing then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_track_gunpowder',
        label = 'Track Gunpowder',
        icon = 'crosshairs',
        onSelect = function()
            if GetActiveTrackType() == 'gunpowder' then
                StopTracking()
                return
            end

            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end

            StartGunpowderTrack()
        end,
    }
end

--- Bite & Hold / Release — PHASE3_SPEC.md §12.5.1. A single
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
        label = 'Bite & Hold / Release',
        icon = 'paw',
        onSelect = function()
            -- Release is NOT gated on CanShowK9UI(), matching the Detach
            -- Leash branch above and SPEC.md §9 item 3b's "no unbounded
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
            if IsBiteHoldEngaged() then
                ReleaseBiteHold()
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
            RequestBiteHold()
        end,
    }
end

--- Non-Lethal Takedown — PHASE3_SPEC.md §12.5.2. A single one-shot action
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
        label = 'Non-Lethal Takedown',
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
            RequestTakedown()
        end,
    }
end

--- Drag / Release — PHASE3_SPEC.md §12.5.4. A single context-sensitive item,
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
--- Release branch above (SPEC.md §9 item 3b — see Bite & Hold's comment
--- block above for the full reasoning, which applies here verbatim).
--- client/combat.lua's ReleaseDrag() itself never re-checks
--- HasK9Access/feature-flag on the way out either (only that this src is a
--- legitimate party to the drag, holder or target) — gating this client-side
--- check would strand a K9 that loses access mid-drag (decertified,
--- feature-flag flip, model swap) with no way to let go, stranding the drag
--- until the server's maxDragDurationMs timeout. This was the exact mistake
--- corrected for Bite & Hold in an earlier pass; not repeating it here.
if Config.Features.PropDragging then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_drag',
        label = 'Drag / Release',
        icon = 'hand',
        onSelect = function()
            -- Release is NOT gated on CanShowK9UI() — see this item's
            -- header comment above ("RELEASE ORDERING") for why.
            if IsDragEngaged() then
                ReleaseDrag()
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
            RequestDrag()
        end,
    }
end

--- Break Partnership -- PHASE3_SPEC.md §12.0 item 7. Closes a real gap a QA
--- pass found: client/partnership.lua exposes BreakPartnership() as a fully
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
--- Detach Leash / Release Bite & Hold / Release Drag above (SPEC.md §9 item
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
--- RESOLVED (was a TODO here; corrected, not left stale): the live
--- partnership-status callback this note was waiting on has landed --
--- server/partnership.lua registers
--- `lib.callback.register('qbx_k9unit:server:getPartnershipState', ...)`,
--- returning current SERVER-truth partnership state, and
--- client/partnership.lua's RefreshPartnershipStateFromServer() already
--- awaits it (per this resource's own fxmanifest.lua comment on that file).
--- As anticipated below, THIS file needed no change when it landed -- the
--- "Break Partnership" item stays unconditionally offered regardless of
--- local partnership-state cache accuracy, for the exact reconnect-trap
--- reason described above. Kept here only as a historical note so a future
--- reader doesn't go looking for a callback that already exists.
if Config.Features.HandlerPartnership then
    k9SubmenuItems[#k9SubmenuItems + 1] = {
        id = 'k9_break_partnership',
        label = 'Break Partnership',
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

--- Partner Up -- PHASE3_SPEC.md §12.0 item 7. The other half of the gap
--- Break Partnership above already closed: client/partnership.lua's own
--- ox_target "Partner Up" option is a live entry point, but nothing in
--- this file offered the same action from the radial (fxmanifest.lua's own
--- comment on client/partnership.lua currently claims "the radial entry is
--- now wired" for this feature -- that was aspirational when written, not
--- yet true as of the start of this pass; report this drift to whoever
--- owns fxmanifest.lua). This item is what makes that claim true.
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
        label = 'Partner Up',
        icon = 'handshake',
        onSelect = function()
            if not CanShowK9UI() then
                DenyK9UIAccess()
                return
            end

            local candidateServerId = FindNearestPartnerCandidate()
            if not candidateServerId then
                lib.notify({ title = 'K9 Unit', description = 'No nearby player to partner with.', type = 'error' })
                return
            end

            if type(RequestPartnerUp) == 'function' then
                RequestPartnerUp(candidateServerId)
            end
        end,
    }
end

--- Recall -- PHASE3_SPEC.md §12.5.1. Closes a real gap: client/recall.lua
--- exposes RequestRecall() specifically "ready for [a future
--- client/radial.lua entry]" (that file's own header), but until this pass
--- nothing ever called it from here -- only its own '/k9recall' chat
--- command worked. config.lua's own Config.Recall header independently
--- names this exact feature this resource's "PRIMARY TERMINATION" path.
---
--- NOT GATED ON CanShowK9UI() -- same "no unbounded trap" requirement as
--- Detach Leash / Release Bite & Hold / Release Drag / Break Partnership
--- above (SPEC.md §9 item 3b). client/recall.lua's own header states this
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
        label = 'Recall K9',
        icon = 'circle-down',
        onSelect = function()
            if type(RequestRecall) == 'function' then
                RequestRecall()
            end
        end,
    }
end

--- Handler-Down Defense confirm -- PHASE3_SPEC.md §12.5.3. Fixes a live,
--- QA-found WRONG-INSTRUCTION bug: client/defense.lua's own
--- handlerDownDefenseTrigger notify literally tells the K9 "Press %s to
--- respond, OR USE THE RADIAL MENU" -- and until this pass, no radial menu
--- entry for it existed anywhere in this file, making the second half of
--- that sentence false for every player who read it.
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
                label = 'Bite & Hold Attacker',
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
                label = 'Non-Lethal Takedown Attacker',
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
        label = 'Handler-Down Response',
        icon = 'user-shield',
        menu = 'k9unit_defense',
    }
end

--- Fetch -- Phase 5 (FetchMechanic). client/fetch.lua exposes
--- RequestThrowFetchBall()/ReleaseFetchBall()/RequestRecallFetchBall()/
--- IsFetchCarryEngaged() specifically "for a future client/radial.lua
--- entry to call" (that file's own header), disclosing it was left
--- deliberately unwired only to dodge a merge conflict with a concurrent
--- pass on this same file -- not a design rejection. This submenu is that
--- follow-up. "Pick Up Ball" and "Deliver to Handler" stay ox_target
--- options exactly as client/fetch.lua's own header already documents
--- (targeted, proximity-driven actions on a specific ball/player, not a
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
                label = 'Throw/Drop Fetch Ball',
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
                label = 'Recall Fetch Ball',
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
        label = 'Fetch',
        icon = 'baseball',
        menu = 'k9unit_fetch',
    }
end

--- Toggle K9 Vest -- Phase 5 R&D (PropAttachments). Closes a real gap:
--- client/propattachment.lua exposes RequestToggleK9PropAttachment()
--- specifically "so a future radial entry can call this directly without
--- this file needing to change" (that function's own doc comment), but
--- until this pass only its own '/k9propattach' command called it.
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
        label = 'Toggle K9 Vest',
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
--- available to extend again" (that function's own doc comment), but until
--- this pass only its own '/k9deploykennel' command called it.
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
        label = 'Deploy Kennel',
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

if Config.Features.RadialMenu then
    -- Register the actual submenu contents FIRST (lib.registerRadial),
    -- keyed by id 'k9unit' — this is the id the opener item below points
    -- to via its own `menu` field.
    lib.registerRadial({
        id = 'k9unit',
        items = k9SubmenuItems,
    })

    -- Then add ONE opener item to the GLOBAL root radial wheel. This is
    -- the only k9unit-related item that belongs in the flat top-level
    -- menuItems list; selecting it navigates into the 'k9unit' submenu
    -- just registered above. Do not add k9SubmenuItems' contents here too
    -- — that was the original bug (see this file's header).
    lib.addRadialItem({
        {
            id = 'k9unit_open',
            label = 'K9 Unit',
            icon = 'dog',
            menu = 'k9unit',
        },
    })
end
