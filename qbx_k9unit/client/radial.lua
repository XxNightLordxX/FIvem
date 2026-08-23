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

-- TODO(coder-frontend): register the "K9 Unit" radial submenu via
-- lib.addRadialItem, per the OPEN STRUCTURAL QUESTION above for how its
-- overall visibility is gated. Sub-items below.

--- Bark — SPEC.md §6.1, §8 step 9. Config.Features.BasicBarkSounds gate.
--- TODO(coder-frontend):
--   1. if not Config.Features.BasicBarkSounds then don't register/show this item end
--   2. onSelect: if not CanShowK9UI() then notify + return end
--      TriggerServerEvent('qbx_k9unit:server:relayBark', 'bark')
--      (server re-validates Config.Features.BasicBarkSounds and
--      HasK9Access independently regardless — see server/main.lua).

--- Sit — SPEC.md §6.1. No dedicated Config.Features flag (bundled under
--- the general RadialMenu flag + access check, same as every other
--- Phase 1 item here).
--- TODO(coder-frontend):
--   onSelect: if not CanShowK9UI() then notify + return end; K9Sit()

--- Attach/Detach Leash — SPEC.md §6.1, §8 step 6-7. A single
--- context-sensitive item: behaves as "Attach" when not currently
--- leashed, "Detach" when leashed. Config.Features.LeashMechanics gate.
--- See client/movement.lua's header for the full consent-based leash
--- design (attach requires the OTHER player to accept; detach never
--- does) — this item is one of two entry points into that same system
--- (the other being the ox_target option client/movement.lua registers
--- directly on nearby players).
--- TODO(coder-frontend):
--   onSelect:
--     if not Config.Features.LeashMechanics then return end
--     if IsLeashed() then DetachLeash() return end
--     if not CanShowK9UI() then notify + return end
--     -- find a nearby candidate partner (nearest other player within
--     -- Config.LeashMaxDistance is a reasonable Phase 1 default — see
--     -- client/movement.lua's header for why that constant does double
--     -- duty as both the attach-initiate range and the post-attach
--     -- auto-detach threshold) and call:
--     RequestLeashAttach(candidateServerId)
--   NOTE: this only SENDS a request — per the consent design, nothing
--   attaches until the target accepts on their own client. Notify the
--   local player "request sent," don't assume success here.

--- Enter/Exit Vehicle — SPEC.md §6.1, §8 step 8. A single
--- context-sensitive item mirroring the ox_target vehicle option
--- client/vehicle.lua registers directly. Config.Features.VehicleEntryExit
--- gate.
--- TODO(coder-frontend):
--   onSelect:
--     if not Config.Features.VehicleEntryExit then return end
--     if not CanShowK9UI() then notify + return end
--     if IsInK9Vehicle() then ExitK9Vehicle() else EnterNearestK9Vehicle() end
