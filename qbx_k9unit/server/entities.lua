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
    - THIS FILE exposes ONE resource-global (no `local`) function:
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
      independently.
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
--- @param netId number
--- @param expectedEntityType number? -- 1 = ped, 2 = vehicle, 3 = object (GetEntityType); omit to skip this check
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
