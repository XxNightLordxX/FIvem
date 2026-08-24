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
