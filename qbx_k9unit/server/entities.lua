--[[
    qbx_k9unit/server/entities.lua

    coder-architect, REFACTOR_ROADMAP.md near-term item 2 ("Extract the
    'resolve network entity defensively' helper — same call, now backed by
    6 real instances instead of 2"). Pure structural extraction, NOT a
    redesign: the SERVER-side half of that item — previously two
    independent hand-written copies of "resolve a client-claimed netId to a
    live entity, defensively" in server/main.lua's relayDoorScratch and
    server/search.lua's HandleSearchTarget — is consolidated into the
    single ResolveNetworkEntity() below, with each call site's own
    existing entity-type/proximity checks preserved (relayDoorScratch's
    object-only restriction and HandleSearchTarget's targetType
    cross-check) — see each call site's own "migrated from X" comment for
    exactly what moved here and what deliberately did not.

    WHY A NEW FILE, NOT FOLDED INTO server/cooldowns.lua: following that
    file's own header rationale verbatim (scope a shared file to ONE
    responsibility so it doesn't balloon into an everything-file as later
    phases add more call sites) — "does this client-claimed netId actually
    resolve to something real" is a genuinely different responsibility
    than a cooldown/mutex timer, and the roadmap's own write-up for this
    item explicitly leaves the file choice open ("either is consistent
    with the shipped precedent now"). Reading that precedent as "one new
    file per distinct responsibility," not "one new file, ever, for
    everything," is the call made here — cooldowns.lua stays scoped to
    timing/mutex state only, and this new primitive gets its own file
    rather than becoming an unrelated second concern bolted onto it.

    Loaded in fxmanifest.lua's server_scripts immediately after
    server/cooldowns.lua and before server/main.lua/server/search.lua.
    Unlike server/cooldowns.lua's constructors (called by those files at
    their own FILE-LOAD time to build private tracker instances),
    ResolveNetworkEntity() below is only ever called at RUN time from
    inside an event/callback handler — so this file's exact position
    relative to main.lua/search.lua isn't itself load-bearing the way
    cooldowns.lua's is, but it's placed alongside it, before both
    consumers, to read in the same "shared primitive first" order that
    file already established.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes TWO resource-global (no `local`) functions:
        ResolveNetworkEntity(netId: number, expectedEntityType: number?) -> number?
      Reused by server/main.lua's relayDoorScratch (called WITH
      expectedEntityType = 3, restricting the resolve to objects only —
      see that call site's own comment for why that number) and
      server/search.lua's HandleSearchTarget (called WITHOUT
      expectedEntityType — that file's own targetType-vs-GetEntityType
      cross-check branches into further target-specific logic beyond a
      simple reject-or-continue gate, so it stays entirely AT that call
      site, deliberately not folded in here; see HandleSearchTarget's own
      comment). Both call sites' existing entity-type/proximity checks are
      preserved exactly — this file only consolidates the common
      "resolve + existence-guard" prefix both of them already did
      independently. As of REFACTOR_ROADMAP.md item 2's Revision 5
      reopening, also reused by server/kennel.lua (3 call sites) and
      server/inventory.lua (1 call site) — see each call site's own
      "migrated from X" comment.
        ResolveConnectedPlayerFromPed(entity: number) -> number?
      REFACTOR_ROADMAP.md item 2b ("scan connected players, match by ped,
      return the server id" — same responsibility as ResolveNetworkEntity
      above, not a new shared-utility concern). Extracted from
      server/search.lua's original `ResolveConnectedPlayerFromPed` (the
      first, most-documented copy — its own "DELIBERATE IMPLEMENTATION
      CHOICE" doc comment, reasoning about why this scans
      GetPlayers()/GetPlayerPed() rather than the unverified
      GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity)) combo, is
      preserved verbatim below since it applies equally to every caller),
      which had been hand-copied verbatim into server/inventory.lua and
      server/combat.lua (three independent copies total, none sharing an
      implementation, before this extraction). Reused by
      server/search.lua's HandleSearchTarget ('person' branch),
      server/inventory.lua's HandleOpenK9Inventory, and
      server/combat.lua's ValidateCombatRequest (player-vs-NPC
      resolution) — every call site's existing use is unchanged, this
      file only consolidates the one shared implementation.
    ======================================================================
]]

--- Resolves a client-claimed network id to a live, currently-existing
--- entity handle, server-side. Returns nil (never 0, and never a
--- stale/nonexistent handle) if `netId` isn't a number, doesn't currently
--- resolve to anything real, or (when `expectedEntityType` is supplied)
--- resolves to an entity whose GetEntityType doesn't match.
---
--- Extracted from two independent hand-written copies of this exact
--- "resolve -> existence-guard" prefix:
--- - server/main.lua's relayDoorScratch: was
---     local doorEntity = NetworkGetEntityFromNetworkId(doorNetId)
---     if doorEntity == 0 or not DoesEntityExist(doorEntity) then return end
---   followed, a few lines later (after the proximity check), by a
---   SEPARATE `if GetEntityType(doorEntity) ~= 3 then return end`. Both
---   checks are preserved here exactly — relayDoorScratch now passes
---   expectedEntityType = 3, which performs the identical type-3-only
---   restriction as one call instead of two, still failing closed on any
---   mismatch. GetEntityType: 1 = ped, 2 = vehicle, 3 = object.
--- - server/search.lua's HandleSearchTarget: was
---     local entity = NetworkGetEntityFromNetworkId(targetNetId)
---     if entity == 0 then return { ok = false, reason = 'invalid_target' } end
---   — no DoesEntityExist call. This helper's existence guard therefore
---   adds that check for every caller including this one: a DELIBERATE,
---   DISCLOSED STRENGTHENING of that call site's existence check, never a
---   weakening. Flagged explicitly, not silently folded in: in practice
---   this is not expected to change observed behavior, since
---   NetworkGetEntityFromNetworkId returning a nonzero handle for an
---   entity that fails DoesEntityExist in the very same tick is not a
---   case this native is documented or observed to produce — the
---   existing "0 or not DoesEntityExist" pairing already treated in
---   relayDoorScratch's own pre-extraction code is belt-and-suspenders,
---   not two independently load-bearing conditions. HandleSearchTarget's
---   targetType cross-check (GetEntityType vs. the caller-claimed
---   'vehicle'/'person', which branches into further person-only
---   resolution logic) is NOT passed as expectedEntityType here and stays
---   entirely at that call site — see server/search.lua's own comment.
--- SECURITY BOUNDARY -- exactly what this function does and does not
--- guarantee, spelled out explicitly since every caller layers its own
--- additional checks on top of this one and needs to know where this
--- function's own guarantee ends (audited as a security primitive, not
--- just a convenience wrapper, per REFACTOR_ROADMAP.md item 2's own
--- "resolve a client-claimed netId defensively" framing):
---
--- GUARANTEES (enforced, not advisory -- every one of these is a hard
--- `return nil`, never a soft/logged pass-through):
---   - `netId` is actually a number (rejects a client payload of the wrong
---     Lua type outright -- see NOTE below on what "a number" does NOT mean).
---   - The entity EXISTS AT THE INSTANT OF THIS CALL (DoesEntityExist,
---     checked in addition to NetworkGetEntityFromNetworkId's own `~= 0`
---     result -- this is a real strengthening over one of the two original
---     pre-extraction call sites, see the doc comment below).
---   - IF `expectedEntityType` is supplied, GetEntityType(entity) matches it
---     EXACTLY. This is enforced, not a hint: a mismatch is a hard `nil`
---     return, identical to a nonexistent entity. There is no partial/
---     advisory mode -- a caller either passes the type it needs and gets a
---     hard reject on mismatch, or omits it and gets zero type filtering at
---     all (see server/search.lua's HandleSearchTarget, which deliberately
---     omits it to run its own richer targetType-vs-GetEntityType branch).
---
--- DOES NOT GUARANTEE (every one of these is the CALLER's own
--- responsibility, and every current caller in this resource does layer
--- its own check for whichever of these it actually needs -- see each call
--- site's own "expectedEntityType = N" / proximity-check comment):
---   - Ownership or proximity. This function has no concept of "belongs to
---     the requesting player" or "is anywhere near the requesting player" --
---     a client can name ANY currently-networked entity of the right type
---     anywhere on the map (another player's vehicle, another player's own
---     ped if expectedEntityType = 1, a prop on the far side of the map) and
---     this function will happily resolve it. Every caller that needs
---     "near me" (server/main.lua's relayDoorScratch) or "belongs to a
---     specific player" (server/combat.lua's self-target reject,
---     server/search.lua's ResolveConnectedPlayerFromPed cross-check) adds
---     that check itself, separately, AFTER this call succeeds.
---   - A specific model/allowlist. GetEntityType only distinguishes
---     ped/vehicle/object (1/2/3) -- it says nothing about WHICH ped model,
---     vehicle model, or object model. Every caller that needs "specifically
---     a K9" (IsConfiguredK9Model) or "specifically a door prop" layers that
---     model check on top, separately, after this call succeeds. Passing
---     expectedEntityType = 1 (ped) narrows "any networked entity" down to
---     "any networked ped" -- it does NOT narrow it to "a K9" or "a specific
---     player's ped".
---   - Continued existence AFTER this call returns. The returned handle is
---     only proven live at the instant this function checked it. It is NOT
---     re-checked, and this function has no way to re-check it later -- a
---     caller that yields (Wait, an `await`ed DB/inventory call) between
---     calling this and actually USING the handle must re-resolve or
---     otherwise re-validate before that later use if the gap matters for
---     its own correctness. Several callers in this resource already do
---     this explicitly (e.g. server/combat.lua's HandleTakedownRequest
---     re-running its full ValidateCombatRequest, including a fresh
---     ResolveNetworkEntity, after its own Wait(); server/search.lua's
---     HandleSearchTarget re-checking `GetPlayerPed(targetServerId) ~=
---     entity` immediately after its own awaited ox_inventory call for the
---     'person' branch) -- that re-validation is the CALLER's job, not
---     something this function can retroactively provide.
---   - That a numeric `netId` is a sane/in-range network id. `type(netId)
---     == 'number'` rejects the wrong Lua type only (a string, a table, nil)
---     -- it does not range-check, floor a non-integer float, or reject a
---     negative number. Any of those simply fail to resolve to a real
---     entity via NetworkGetEntityFromNetworkId (which returns 0 for
---     anything it doesn't recognize) and fall through to this function's
---     own `entity == 0` guard below, so they're still rejected -- just via
---     the existence check, not the type check.
--- @param netId number
--- @param expectedEntityType number? -- 1 = ped, 2 = vehicle, 3 = object (GetEntityType); omit to skip this check. Enforced (hard reject on mismatch), not advisory -- see this doc comment's GUARANTEES section above.
--- @return number? entity
function ResolveNetworkEntity(netId, expectedEntityType)
    if type(netId) ~= 'number' then return nil end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    if expectedEntityType and GetEntityType(entity) ~= expectedEntityType then
        return nil
    end

    return entity
end

--- Resolves a ped entity to the currently-connected player's server id it
--- belongs to, or nil if it doesn't belong to any currently-connected
--- player (an NPC, or a stale/despawned handle).
---
--- REFACTOR_ROADMAP.md item 2b. Extracted from three independent,
--- byte-identical hand-written copies of this exact function:
--- server/search.lua's original (the first-written, most-documented copy,
--- whose own doc comment is preserved below verbatim), server/inventory.lua's
--- `HandleOpenK9Inventory` (a "small local copy vs. expanding another
--- file's contract" duplicate, per that file's own now-obsolete
--- FILE-TO-FILE CONTRACT note), and server/combat.lua's
--- `ValidateCombatRequest` player-vs-NPC resolution (whose own header
--- already flagged this as an extraction candidate "now that there are
--- two" — stale on arrival, since server/inventory.lua had already made it
--- three). All three now call this single function instead.
---
--- DELIBERATE IMPLEMENTATION CHOICE, flagged for coder-security (preserved
--- from server/search.lua's original doc comment — this reasoning applies
--- equally to every caller, not just the one that first wrote it): the
--- design notes server/search.lua was built from
--- (phase2_notes/contraband_search_contract.md §3 step 9, and that file's
--- own prior scaffold) suggested
--- `GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))` for this
--- resolution. That combination was never independently re-verified as
--- reliably callable SERVER-side (both natives are historically associated
--- with the client-side "local player pool" concept, which the FXServer
--- process — running no game-world simulation at all — may not expose the
--- same way). Rather than depend on an unverified native combo for a
--- security-relevant check, this resolves the same fact (does this entity
--- belong to a real, currently-connected player?) using only natives
--- already proven reliable SERVER-side elsewhere in this exact codebase
--- (`GetPlayers()`/`GetPlayerPed(source)` — already used in
--- server/certifications.lua and server/main.lua): scan every connected
--- player's own ped and match by entity handle. This is strictly more
--- conservative (it can only ever match an entity that IS some connected
--- player's own ped) and avoids introducing a new, unverified native
--- dependency on this security-sensitive check.
--- @param entity number
--- @return number? targetServerId
function ResolveConnectedPlayerFromPed(entity)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if playerId and GetPlayerPed(playerId) == entity then
            return playerId
        end
    end
    return nil
end
