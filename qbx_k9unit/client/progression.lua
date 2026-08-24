--[[
    qbx_k9unit/client/progression.lua

    Phase 4 (coder-backend). Client half of `Config.Features.XPProgression`
    (server/progression.lua owns the server-authoritative half — award
    logic, persistence, the tier lookup). THIS FILE has NO authority of its
    own: it only ever RECEIVES an already-resolved, server-computed tier and
    reflects it locally — it never computes XP, never claims a tier to the
    server, and never accumulates anything (PHASE4_SPEC.md §13.0 Decision 3:
    XP and its derived tier are server-authoritative state, full stop).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4. Identical in format to
    client/tracking.lua's own contract block.

    Callbacks: none.

    Server events (client->server): NONE for XP itself — see
    server/progression.lua's own header for why no "I earned XP" event
    exists or should ever exist.

    Client events (RegisterNetEvent, server->client):
    1. 'qbx_k9unit:client:xpTierChanged' (newTier: table — a full entry from
       Config.XPTiers: { xp, label, speedMultiplier, scentRange })
       [THIS FILE] — sent on PlayerLoaded/resource-start backfill (an
       authoritative snapshot, not a "level up") and on any real tier
       crossing (server/progression.lua's AwardXP). This file cannot tell
       those two cases apart from the payload alone, and doesn't need to for
       CORRECTNESS (the speedMultiplier is applied identically either way) —
       it only matters for whether to show a "tier up" notification, handled
       below via `hasReceivedInitialTier` (never notify on the very first
       snapshot a session receives, since there is no prior client-side tier
       to have "leveled up" from).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        GetCurrentXPTier() -> table|nil
            The last tier snapshot pushed by the server this session, or nil
            before the first 'qbx_k9unit:client:xpTierChanged' arrives
            (briefly, right after connect, before PlayerLoaded's server-side
            backfill round-trips back). Exposed for a future HUD/display
            need (PHASE4_SPEC.md §13.4.1's own "additive read, not a new
            authorization surface" framing) — not currently consumed
            anywhere else in this resource.
    - COORDINATION POINT WITH THE SHARED MOVE-RATE COMPOSER (PHASE4_SPEC.md
      §13.0 Decision 2, §13.5): by the time Phase 3's PropDragging and this
      phase's wellbeing subsystem both exist, at least three independent
      systems want to call SetPedMoveRateOverride on the K9's own ped —
      last-caller-wins on that native means uncoordinated calls silently
      clobber each other. The spec's answer is a SINGLE shared composer,
      `RecomputeK9MoveRate()` + a `K9MoveRateModifiers` table (both intended
      to live in client/movement.lua, owned by whichever of {wellbeing
      subsystem, Phase 3 PropDragging} lands first per §13.5), where every
      contributing system sets its OWN named slot
      (`K9MoveRateModifiers.xpTier` for this file) and calls
      `RecomputeK9MoveRate()` rather than calling the native directly.
      NEITHER SYMBOL EXISTS IN THIS CODEBASE AS OF THIS PASS (verified by
      grep immediately before writing this file — no client/wellbeing.lua,
      no server/combat.lua, no composer in client/movement.lua yet). Per
      this task's own explicit direction, THIS FILE THEREFORE DOES NOT CALL
      SetPedMoveRateOverride ITSELF — doing so would be exactly the
      uncoordinated-caller bug §13.0 Decision 2 exists to prevent. Instead:
        - `CachedXPTierSpeedMultiplier` (below) always holds the latest
          server-pushed tier's speedMultiplier, updated on every
          xpTierChanged event, regardless of whether the composer exists
          yet.
        - `ApplyXPTierMoveRateEffect()` (below) is THIS FILE's own
          clearly-named, separately-callable contribution: if
          `K9MoveRateModifiers` exists (a plain table check, not a function
          call — the spec names it as a shared table, not a function), it
          writes `K9MoveRateModifiers.xpTier = CachedXPTierSpeedMultiplier`
          and then calls `RecomputeK9MoveRate()` IF that also exists
          (`type(...) == 'function'` guard, mirroring server/medkit.lua's
          established `type(RestoreInjury) == 'function'` soft-dependency
          convention for the identical "the other half of this hasn't
          shipped yet" situation). If the composer does not exist yet, this
          function is a harmless no-op beyond updating the cached value —
          it does NOT fall back to calling SetPedMoveRateOverride directly.
        - TODO(coordination, whoever lands client/movement.lua's composer
          second): once `K9MoveRateModifiers`/`RecomputeK9MoveRate()` exist
          for real, no change is needed HERE — this file already writes to
          the exact slot name (`.xpTier`) PHASE4_SPEC.md §13.0 Decision 2
          specifies. Just confirm the slot name/table shape this file
          already assumes still matches what actually shipped before
          treating this coordination point as closed (per PHASE4_SPEC.md
          §13.5's own "whichever phase lands second should confirm the
          dependency against the other phase's actual shipped code" rule).
    ======================================================================
]]

--- Last tier snapshot received from the server this session, or nil before
--- the first 'qbx_k9unit:client:xpTierChanged' event arrives. Not exposed
--- directly — always go through GetCurrentXPTier().
--- @type table|nil
local currentXPTier = nil

--- Guards the "tier up" notification below from firing on the very first
--- snapshot a session receives (PlayerLoaded's own backfill push) — see
--- this file's EVENT/CALLBACK CONTRACT note above for why the payload alone
--- can't distinguish "initial snapshot" from "real tier change."
local hasReceivedInitialTier = false

--- Always holds the latest server-authoritative tier's speedMultiplier —
--- see the FILE-TO-FILE CONTRACT's "COORDINATION POINT" section above for
--- why this exists independently of whether the shared move-rate composer
--- has shipped yet.
local CachedXPTierSpeedMultiplier = 1.0

--- Resource-global — see FILE-TO-FILE CONTRACT above.
--- @return table|nil
function GetCurrentXPTier()
    return currentXPTier
end

--- THIS FILE's own clearly-named, separately-callable contribution to the
--- shared move-rate composer described in the FILE-TO-FILE CONTRACT's
--- "COORDINATION POINT" section above. Deliberately NEVER calls
--- SetPedMoveRateOverride itself — see that section for the full reasoning.
local function ApplyXPTierMoveRateEffect()
    if K9MoveRateModifiers then
        K9MoveRateModifiers.xpTier = CachedXPTierSpeedMultiplier
    end
    -- else: the shared composer (client/movement.lua, PHASE4_SPEC.md §13.0
    -- Decision 2) has not shipped yet as of this pass — see this file's
    -- header TODO. CachedXPTierSpeedMultiplier above still holds the
    -- correct, current, server-authoritative value, ready to be applied the
    -- moment the composer exists; nothing further to do here in the
    -- meantime, and specifically NOT a fallback direct
    -- SetPedMoveRateOverride call.

    if type(RecomputeK9MoveRate) == 'function' then
        RecomputeK9MoveRate()
    end
end

--- @param newTier table -- { xp, label, speedMultiplier, scentRange }, a full Config.XPTiers entry
RegisterNetEvent('qbx_k9unit:client:xpTierChanged', function(newTier)
    -- Defensive shape validation even though this is server-authoritative
    -- (never a client-supplied claim) — cheap, and this codebase's own
    -- convention (e.g. client/tracking.lua's `not result or not
    -- result.found` guard on its own server callback response) is to never
    -- assume a network payload arrives well-formed, regardless of which
    -- side sent it.
    if type(newTier) ~= 'table' or type(newTier.speedMultiplier) ~= 'number' then
        return
    end

    local previousTier = currentXPTier
    currentXPTier = newTier
    CachedXPTierSpeedMultiplier = newTier.speedMultiplier

    ApplyXPTierMoveRateEffect()

    -- Only notify on a REAL tier change after this session's initial
    -- snapshot has already been received once — never on that first
    -- snapshot itself (there is no prior client-side tier to have "leveled
    -- up" from at that point), and never for a no-op repeat of the same
    -- tier (defensive — server/progression.lua only pushes on an actual
    -- crossing today, but this file doesn't assume that invariant holds
    -- forever).
    if hasReceivedInitialTier and previousTier ~= newTier and previousTier and previousTier.label ~= newTier.label then
        lib.notify({
            title = 'K9 Unit',
            description = ('Your K9 has reached the %s tier!'):format(tostring(newTier.label)),
            type = 'success',
        })
    end

    hasReceivedInitialTier = true
end)
