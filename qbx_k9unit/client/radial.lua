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

    BARK TYPE NOTE: Phase 1 needs exactly one generic bark (§6.1: "Basic
    bark sound plays on a radial-triggered 'Bark' action" — the
    aggressive/alert/calm variety is Phase 5's AdvancedBarkRadial, not
    Phase 1). Use a single literal string, e.g. 'bark', consistently with
    server/main.lua's relayBark TODO and client/main.lua's playBark TODO —
    all three call sites must agree on the same literal until this gets
    promoted to a real config-driven enum (flagged in those files too).
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
-- of seconds for every player near a PD, and avoids depending on
-- lib.addRadialItem/lib.removeRadialItem ordering semantics for a
-- submenu-then-children relationship that isn't verified against ox_lib's
-- source from this session. Documented here for qa-tester/
-- integration-verifier: "appears" in this file means "is present in the
-- radial wheel," not "is currently usable" — usability is enforced at
-- onSelect time, same as every gated server event is independently
-- re-verified server-side regardless of what the client shows.
local function DenyNotify()
    lib.notify({ title = 'K9 Unit', description = 'You cannot use K9 features right now.', type = 'error' })
end

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

local k9RadialItems = {
    { id = 'k9unit', label = 'K9 Unit', icon = 'dog' },

    --- Sit — SPEC.md §6.1. No dedicated Config.Features flag (bundled
    --- under the general RadialMenu flag + access check, same as every
    --- other Phase 1 item here).
    {
        id = 'k9_sit',
        label = 'Sit',
        icon = 'couch',
        menu = 'k9unit',
        onSelect = function()
            if not CanShowK9UI() then
                DenyNotify()
                return
            end
            K9Sit()
        end,
    },
}

--- Bark — SPEC.md §6.1, §8 step 9. Config.Features.BasicBarkSounds gate.
if Config.Features.BasicBarkSounds then
    k9RadialItems[#k9RadialItems + 1] = {
        id = 'k9_bark',
        label = 'Bark',
        icon = 'volume-high',
        menu = 'k9unit',
        onSelect = function()
            if not CanShowK9UI() then
                DenyNotify()
                return
            end
            -- server re-validates Config.Features.BasicBarkSounds and
            -- HasK9Access independently regardless — see server/main.lua.
            TriggerServerEvent('qbx_k9unit:server:relayBark', 'bark')
        end,
    }
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
    k9RadialItems[#k9RadialItems + 1] = {
        id = 'k9_leash',
        label = 'Attach/Detach Leash',
        icon = 'link',
        menu = 'k9unit',
        onSelect = function()
            -- Detach never requires consent/access — always available
            -- while leashed, per SPEC.md §9 item 3b's hard requirement.
            if IsLeashed() then
                DetachLeash()
                return
            end

            if not CanShowK9UI() then
                DenyNotify()
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
    k9RadialItems[#k9RadialItems + 1] = {
        id = 'k9_vehicle',
        label = 'Enter/Exit Vehicle',
        icon = 'car',
        menu = 'k9unit',
        onSelect = function()
            if not CanShowK9UI() then
                DenyNotify()
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

if Config.Features.RadialMenu then
    lib.addRadialItem(k9RadialItems)
end
