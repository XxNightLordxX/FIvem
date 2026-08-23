--[[
    qbx_k9unit/server/search.lua

    Phase 2 implementation (coder-backend). THIS IS THE SECURITY-CRITICAL
    FILE OF PHASE 2, per SPEC.md §11.1 sub-phase 2b ("this is also the
    piece coder-security should review first, per the task's explicit
    direction to confirm search results can't be client-claimed") and per
    phase2_notes/contraband_search_contract.md's own framing ("designing
    early because the trust boundary doesn't move even if config field
    names do"). Get an explicit coder-security sign-off on this
    implementation before it ships, the same standard
    server/certifications.lua's header already sets for §4's grant/revoke
    flow.

    Owns (SPEC.md §11.3's `server/search.lua` row): the
    `qbx_k9unit:server:searchTarget` callback — server-authoritative
    "search vehicle/person for contraband" (§6.3/§11.5), including the
    contraband-alert broadcast (§11.4 item 2, gated on
    Config.Features.ContrabandAlerts). New file, not folded into
    server/main.lua, for the SAME "real capability grant deserves the
    certification-file's level of scrutiny" reasoning §11.3 gives for
    splitting client/search.lua from client/tracking.lua by TRUST MODEL,
    not feature name: this file reads a target's REAL, live ox_inventory
    contents — the same category of real capability grant as
    server/certifications.lua's grant/revoke — whereas server/tracking.lua
    (this file's sibling) only ever reveals a client-cosmetic marker trail
    (SPEC.md §11.6, no real capability granted).

    AUTHORITATIVE SOURCES FOR THIS FILE'S BODY, IN ORDER OF PRECEDENCE:
    1. SPEC.md §11.4 item 2 (event/callback contract) and §11.5's
       "Search vehicle/person + contraband alert tiers" acceptance
       criteria — the base contract this file satisfies.
    2. phase2_notes/contraband_search_contract.md — supplements §11.4/
       §11.5 with the exact server-authoritative validation order (§3), the
       REAL confirmed ox_inventory export surface (§1 —
       `GetInventoryItems`, `GetContainerFromSlot`, read against the actual
       overextended/ox_inventory source, not guessed), the mandatory
       container-recursion requirement (§2), and the race-safe
       rate-limiting/mutex design (§4).
    3. phase2_notes/contraband_search_security_review.md — every BLOCKING
       finding in its §8 summary is implemented below as a hard
       requirement, not optional hardening:
         - Blocking: contraband alert broadcast is DISTANCE-FILTERED (see
           BroadcastContrabandAlert below), never a global `-1` broadcast
           like relayBark's (§1).
         - Blocking: broadcast payload carries `netId` + `alertTier` ONLY —
           never `totalWeight`/`contrabandFound` (§1).
         - Flat per-source cooldown on `searchTarget` (ANY target),
           independent of the existing per-(source, target) cooldown (§2).
         - Per-pair cooldown timestamp written BEFORE the awaited
           ox_inventory read, not after (§3).
         - Resolved entity's REAL type cross-validated against the claimed
           `targetType`; for 'person', confirmed to resolve to a
           currently-connected player before being treated as searchable
           (§4).
         - Explicit, stated decision (not a silent default) on whether a
           per-target-ONLY backstop cooldown exists — see HandleSearchTarget's
           doc comment below for the decision made and its rationale (§5).
         - citizenid, not raw ped netId, keys the person-search cooldown
           (§7).

    Coordinator amendment (2026-08-23, this pass): Config.SearchZones.alertBroadcastRadius
    is the max distance from the SEARCHED TARGET's own live coordinates
    for a bystander to receive the alert broadcast — never a global
    broadcast, per the security review above.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2. Identical in format to
    server/certifications.lua's contract block.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:searchTarget' (targetType: 'vehicle'|'person', targetNetId: number)
       -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
       [THIS FILE]
       See HandleSearchTarget's own doc comment below for the full
       validation order.

    Server events (RegisterNetEvent, client->server): none. This feature
    is entirely request/response shaped — there is deliberately no
    fire-and-forget "I searched" event.

    Client events (RegisterNetEvent, server->client):
    2. 'qbx_k9unit:client:playContrabandAlert' (netId: number, alertTier: string)
       [client/search.lua] — the distance-filtered broadcast described in
       BroadcastContrabandAlert below. NOTE the DELIBERATE ABSENCE of
       `totalWeight`/`contrabandFound` in this payload — see the security
       review's blocking finding §1. `netId` here is the SEARCHED TARGET's
       own netId (the vehicle/ped that was flagged), not the requesting
       K9's — the client needs to know which entity to play the reaction
       on/near.

    Commands: none.

    Automatic path: none.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)`, resource-global from
      server/certifications.lua — reused, never re-derived. Does NOT call
      `IsConfiguredK9Model` — a search requester's eligibility is pure
      job+certification (HasK9Access), same posture as
      server/tracking.lua's own FILE-TO-FILE CONTRACT note for the same
      reason.
    - THIS FILE exposes NO resource-global functions.
    - THIS FILE owns `SearchInFlight`, `lastSearchAt`, and
      `lastTargetSearchAt` below as file-local state — see each table's
      own doc comment for why each exists.
    ======================================================================
]]

-- In-flight mutex per source (contraband_search_contract.md §4A). Set
-- synchronously, BEFORE any yielding work, checked immediately after the
-- cheap validation steps (payload shape, feature flag, access) and before
-- any cooldown/entity-resolution work, cleared on EVERY exit path
-- (success, failure, AND error) so a thrown error inside the ox_inventory
-- call doesn't permanently wedge that source out of ever searching again.
-- SearchInFlight[source] = true | nil
local SearchInFlight = {}

-- Flat per-source cooldown — BLOCKING per
-- contraband_search_security_review.md §2 ("nothing stops a single
-- source from searching many different targets back-to-back with zero
-- delay"). Sized around Config.SearchZones.sniffAnimDurationMs (that
-- finding's own suggestion). Mirrors BARK_COOLDOWN_MS/lastBarkAt's exact
-- shape in server/main.lua. Cleared on playerDropped.
-- lastSearchAt[source] = <GetGameTimer() ms>
local lastSearchAt = {}

-- Per-resolved-target cooldown backing Config.SearchZones.searchCooldownMs
-- — keyed on the RESOLVED, STABLE identity (plate for vehicles; citizenid
-- for persons, per contraband_search_security_review.md §7's "survives a
-- ped-recreation edge case" note), NOT the raw client-supplied
-- `targetNetId` (recyclable/spoofable-adjacent, contraband_search_contract.md
-- §4B). Outlives any single player's connection (a plate persists after
-- the searching officer disconnects), so — unlike lastSearchAt/SearchInFlight
-- above — this table needs its OWN independent TTL-based sweep instead of
-- playerDropped-based cleanup, see PruneTargetSearchCooldowns below.
-- lastTargetSearchAt['vehicle:<plate>' | 'person:<citizenid>'] = <GetGameTimer() ms>
local lastTargetSearchAt = {}

-- Precomputed set of configured contraband item names, built once at file
-- load (config.lua is a shared_script loaded before this file). O(1)
-- membership test instead of re-scanning Config.SearchContrabandItems per
-- inventory slot.
local ContrabandItemSet = {}
for _, itemName in ipairs(Config.SearchContrabandItems) do
    ContrabandItemSet[itemName] = true
end

-- Container recursion depth cap (contraband_search_contract.md §2 —
-- "an explicitly chosen max depth (e.g. 3) — not unbounded, and not
-- skipped"). Deliberately a LOCAL implementation constant, not a
-- Config.* field — recursion depth is an internal defensive bound of this
-- file's own scan logic, not a server-owner tuning knob.
local MAX_CONTAINER_RECURSION_DEPTH = 3

--- Recursively sums the weight of every slot (top-level + nested
--- containers, up to MAX_CONTAINER_RECURSION_DEPTH) in `items` whose
--- `.name` is a configured contraband item (contraband_search_contract.md
--- §2 — "must-handle, not optional polish": a naive top-level-only scan
--- will not match a bag's OWN item name against Config.SearchContrabandItems,
--- so "put the drugs in a bag" would otherwise be a trivial, fully-defeating
--- bypass). `.weight` on each ItemSlot is ALREADY the total weight for
--- that slot (item.weight * slot.count, plus adjustments) per the
--- contract doc's confirmed read of the real ox_inventory source — do NOT
--- re-multiply by `.count` here, that would double-count.
--- @param inventoryId string|number -- needed to resolve child containers via GetContainerFromSlot
--- @param items table<number, table>? -- GetInventoryItems' return shape
--- @param depth number -- 1 for the initial top-level call
--- @return number totalWeight
local function SumContrabandWeight(inventoryId, items, depth)
    local total = 0
    if not items then return total end

    for _, slot in pairs(items) do
        if ContrabandItemSet[slot.name] then
            total = total + (slot.weight or 0)
        end

        if depth < MAX_CONTAINER_RECURSION_DEPTH then
            -- A non-container slot simply resolves to nil/false here —
            -- pcall-wrapped since a mid-scan entity/inventory change could
            -- make this error rather than cleanly return nil.
            local containerOk, containerInv = pcall(function()
                return exports.ox_inventory:GetContainerFromSlot(inventoryId, slot.slot)
            end)
            if containerOk and containerInv and containerInv.items then
                total = total + SumContrabandWeight(containerInv.id or inventoryId, containerInv.items, depth + 1)
            end
        end
    end

    return total
end

--- Resolves `totalWeight` to a tier from Config.ContrabandAlertTiers.
--- Coordinator amendment (2026-08-23): the config's baseline
--- `{ minWeight = 0, alert = 'clean' }` entry is mandatory and sorted
--- first (ascending by minWeight) — walk the whole list and keep the LAST
--- tier whose minWeight the total meets or exceeds, so a zero-contraband
--- result always resolves to 'clean' rather than falling through
--- unhandled. Does not assume the list is sorted defensively (falls back
--- to the first entry if somehow none matched, which cannot happen given
--- the mandatory `minWeight = 0` baseline, but avoids ever returning nil).
--- @param totalWeight number
--- @return table tier -- { minWeight, alert }
local function ResolveAlertTier(totalWeight)
    local resolvedTier = Config.ContrabandAlertTiers[1]
    for _, tier in ipairs(Config.ContrabandAlertTiers) do
        if totalWeight >= tier.minWeight then
            resolvedTier = tier
        end
    end
    return resolvedTier
end

--- BLOCKING per contraband_search_security_review.md §1: iterates
--- connected players and only notifies those within
--- Config.SearchZones.alertBroadcastRadius of the TARGET's own live
--- coordinates — NEVER a global TriggerClientEvent(-1, ...) like
--- relayBark's, since (unlike a bark) this payload identifies a specific
--- vehicle/person just flagged for contraband; a global broadcast would
--- leak that fact to an accomplice anywhere on the map. Payload carries
--- ONLY `targetNetId` + `alertTier` — NEVER `totalWeight`/`contrabandFound`
--- (security review §1's "secondary" finding).
--- @param targetCoords vector3 -- the searched target's own live coords, resolved server-side
--- @param targetNetId number -- the searched target's own netId (client-supplied but already verified to resolve to this exact entity by the time this is called)
--- @param alertTierName string
local function BroadcastContrabandAlert(targetCoords, targetNetId, alertTierName)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if playerId then
            local ped = GetPlayerPed(playerId)
            if ped ~= 0 then
                local dist = #(GetEntityCoords(ped) - targetCoords)
                if dist <= Config.SearchZones.alertBroadcastRadius then
                    TriggerClientEvent('qbx_k9unit:client:playContrabandAlert', playerId, targetNetId, alertTierName)
                end
            end
        end
    end
end

-- An entry older than its own cooldown window is by definition no longer
-- doing any rate-limiting work and is safe to drop (contraband_search_contract.md
-- §4). Not the same table/schedule as server/tracking.lua's TrackableLog
-- prune pass — unrelated tables, unrelated reasons, do not merge the
-- threads.
local TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS = 60000

local function PruneTargetSearchCooldowns()
    local now = GetGameTimer()
    local staleAfterMs = Config.SearchZones.searchCooldownMs * 2
    for key, loggedAt in pairs(lastTargetSearchAt) do
        if (now - loggedAt) > staleAfterMs then
            lastTargetSearchAt[key] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(TARGET_SEARCH_COOLDOWN_PRUNE_INTERVAL_MS)
        PruneTargetSearchCooldowns()
    end
end)

--- Resolves a ped entity to the currently-connected player's server id it
--- belongs to, or nil if it doesn't belong to any currently-connected
--- player (an NPC, or a stale/despawned handle).
---
--- DELIBERATE IMPLEMENTATION CHOICE, flagged for coder-security: the
--- design notes this file is built from (phase2_notes/contraband_search_contract.md
--- §3 step 9, and this file's own prior scaffold) suggested
--- `GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))` for this
--- resolution. That combination was never independently re-verified this
--- session as reliably callable SERVER-side (both natives are
--- historically associated with the client-side "local player pool"
--- concept, which the FXServer process — running no game-world simulation
--- at all — may not expose the same way). Rather than depend on an
--- unverified native combo for a security-relevant check, this resolves
--- the same fact (does this entity belong to a real, currently-connected
--- player?) using only natives already proven reliable SERVER-side
--- elsewhere in this exact codebase (`GetPlayers()`/`GetPlayerPed(source)`
--- — both already used in server/certifications.lua and server/main.lua):
--- scan every connected player's own ped and match by entity handle. This
--- is strictly more conservative (it can only ever match an entity that
--- IS some connected player's own ped) and avoids introducing a new,
--- unverified native dependency on the single most security-sensitive
--- check in this file.
--- @param entity number
--- @return number? targetServerId
local function ResolveConnectedPlayerFromPed(entity)
    for _, playerIdStr in ipairs(GetPlayers()) do
        local playerId = tonumber(playerIdStr)
        if playerId and GetPlayerPed(playerId) == entity then
            return playerId
        end
    end
    return nil
end

--- Fire-and-forget audit log write to `k9_search_log`
--- (sql/install.sql — see that table's own header comment for the full
--- db-schema rationale and integration note this function implements).
--- Non-blocking (`MySQL.insert(...)` WITHOUT `.await`) so a slow/contended
--- DB write never delays or risks the searchTarget callback's own
--- response to the requesting officer — and pcall-wrapped for the same
--- reason: a logging failure must never surface as (or cause) a search
--- failure to the caller. Only called for outcomes that reached a real
--- inventory-read attempt (`'found'|'clean'|'search_failed'`) — never for
--- early rejections (feature_disabled/no_access/search_in_progress/
--- on_cooldown/too_far/invalid_target), per the table's own documented
--- scope (those never touched the target's real inventory and carry no
--- forensic value for "did a search actually happen").
--- @param source number
--- @param targetType 'vehicle'|'person'
--- @param plateOrNil string?
--- @param targetCitizenidOrNil string?
--- @param result 'found'|'clean'|'search_failed'
--- @param totalWeightOrNil number?
--- @param alertTierOrNil string?
local function LogSearchAttempt(source, targetType, plateOrNil, targetCitizenidOrNil, result, totalWeightOrNil, alertTierOrNil)
    -- CORRECTION to sql/install.sql's own integration-note wording
    -- (regression-tester finding): that comment says to "prefer whatever
    -- job value HasK9Access already resolved... over re-deriving it" —
    -- but HasK9Access(source) only ever returns a boolean, it never
    -- exposes the job name it checked internally. There is nothing to
    -- reuse; this independently re-derives searcher_job from
    -- exports.qbx_core:GetPlayer(source).PlayerData.job.name below, same
    -- as every other citizenid/job lookup in this codebase. Don't go
    -- looking for a HasK9Access return value that doesn't exist.
    local searcherPlayer = exports.qbx_core:GetPlayer(source)
    local searcherData = searcherPlayer and searcherPlayer.PlayerData
    local searcherCitizenid = searcherData and searcherData.citizenid
    local searcherJob = searcherData and searcherData.job and searcherData.job.name
    if not searcherCitizenid or not searcherJob then return end -- defensive: nothing sane to log

    pcall(MySQL.insert, [[
        INSERT INTO k9_search_log
            (searcher_citizenid, searcher_job, target_type, target_plate, target_citizenid, result, total_weight, alert_tier)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        searcherCitizenid, searcherJob, targetType, plateOrNil, targetCitizenidOrNil, result, totalWeightOrNil, alertTierOrNil,
    })
end

--- Internal implementation for the searchTarget callback below. Called
--- only after the callback's own cheap checks (payload shape, feature
--- flag, HasK9Access, in-flight mutex, flat per-source cooldown) already
--- passed. Any error thrown from within here (most commonly an
--- ox_inventory export call) is caught by the caller's outer pcall and
--- reported as `{ ok = false, reason = 'search_failed' }`.
---
--- Validation order — cheapest/most-defensive checks first, expensive/
--- leaky ones last (contraband_search_contract.md §3's own framing;
--- reordering "for convenience," e.g. moving the inventory read before
--- the proximity check, silently reopens the map-wide oracle this
--- ordering exists to prevent):
---   1. Resolve `targetNetId` to a live entity — reject if it doesn't
---      exist (despawned, garbage netId, or never existed).
---   2. Cross-check the resolved entity's REAL type against the CLAIMED
---      `targetType` (BLOCKING, security review §4) — closes the
---      spoofing angle where a client sends `targetType = 'vehicle'` but
---      a ped's netId (or vice versa) to probe a mismatched code path.
---      For 'person', additionally confirms the ped resolves to a REAL,
---      currently-connected player (never an NPC) via
---      ResolveConnectedPlayerFromPed above — Phase 2's "person" search is
---      player-only per SPEC.md §11.3's own scoping note.
---   3. MANDATORY, FIRST-CLASS live proximity check, run BEFORE any
---      ox_inventory query, unconditionally (contract doc §3 step 8 / §6:
---      without this, a modified client could supply the netId of ANY
---      vehicle/player anywhere on the map and get back a real
---      contrabandFound/totalWeight result, turning this into a
---      server-wide "scan any vehicle for drugs" oracle).
---   4. Derive the resolved, STABLE cooldown identity (plate/citizenid,
---      never the raw client-supplied targetNetId) and check the
---      per-(K9, target) cooldown.
---   5. Stamp BOTH cooldowns (flat per-source AND per-target) NOW, BEFORE
---      the awaited ox_inventory call below (BLOCKING, security review
---      §3 / contract doc §3 step 13) — writing the cooldown after an
---      awaited call leaves a window where a second call for the same
---      source/target can interleave before the first stamps anything,
---      causing a double-search/double-broadcast.
---   6. Derive the real inventory id server-side ONLY now — never
---      anything client-supplied.
---   7. Query contents via ox_inventory, pcall-wrapped — a caught error or
---      a `nil` result is `search_failed`, NEVER collapsed into
---      `contrabandFound = false` (conflating "we couldn't check" with
---      "we checked and it's clean" is a correctness bug with real
---      in-fiction consequences).
---   8. Recurse into containers (SumContrabandWeight), sum weight, resolve
---      the alert tier.
---   9. If Config.Features.ContrabandAlerts and the tier isn't 'clean',
---      broadcast (distance-filtered, tier-only payload).
---  10. Return the full result (including totalWeight) to the CALLER
---      ONLY — this is the one place totalWeight is allowed to appear.
---
--- EXPLICIT DECISION, not a silent default (security review §5): this
--- implementation does NOT add a per-target-ONLY backstop cooldown
--- independent of searcher identity. Multiple distinct, legitimately
--- certified K9 officers can each search the same target once their own
--- per-pair cooldown allows — treated as intended behavior (multiple
--- units working a scene should each be able to verify independently),
--- not a gap, now that finding §1 (distance-filtered, tier-only broadcast)
--- means a repeat search never leaks more information to bystanders than
--- a single search already did. Flagged here explicitly for
--- coder-security to confirm or override, per the security review's own
--- framing that either answer is defensible.
---
--- Search-action audit logging (contract doc §6's last bullet: who
--- searched what/whom, when, result) is NOT an open question — db-schema
--- already decided YES and shipped `k9_search_log` in sql/install.sql with
--- a full integration note. Wired here via LogSearchAttempt (see its own
--- doc comment above and its two call sites below, for 'search_failed' and
--- for 'found'/'clean').
--- @param source number
--- @param targetType 'vehicle'|'person'
--- @param targetNetId number
--- @param requestedAt number -- GetGameTimer() at the moment the flat cooldown check passed, reused as the single timestamp for both cooldown stamps
--- @return table result
local function HandleSearchTarget(source, targetType, targetNetId, requestedAt)
    local entity = NetworkGetEntityFromNetworkId(targetNetId)
    if entity == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    -- Cross-check the resolved entity's REAL type against the CLAIMED
    -- targetType. GetEntityType: 1 = ped, 2 = vehicle, 3 = object
    -- (well-established FiveM native behavior).
    local entityType = GetEntityType(entity)
    local citizenid, targetServerId

    if targetType == 'vehicle' then
        if entityType ~= 2 then
            return { ok = false, reason = 'invalid_target' }
        end
    else -- 'person'
        if entityType ~= 1 then
            return { ok = false, reason = 'invalid_target' }
        end

        targetServerId = ResolveConnectedPlayerFromPed(entity)
        if not targetServerId then
            return { ok = false, reason = 'invalid_target' } -- NPC, or no longer a connected player's ped
        end

        local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
        citizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
        if not citizenid then
            return { ok = false, reason = 'invalid_target' }
        end
    end

    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any
    -- ox_inventory query, unconditionally.
    local requesterPed = GetPlayerPed(source)
    if requesterPed == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    local maxDistance = targetType == 'vehicle' and Config.SearchZones.vehicleSearchDistance or Config.SearchZones.personSearchDistance
    local dist = #(GetEntityCoords(requesterPed) - GetEntityCoords(entity))
    if dist > maxDistance then
        return { ok = false, reason = 'too_far' }
    end

    -- Derive the resolved, STABLE cooldown identity and the real
    -- ox_inventory inventory id — NEVER anything client-supplied. `plate`
    -- is hoisted to this outer scope (rather than staying local to the
    -- 'vehicle' branch below) because LogSearchAttempt, at the bottom of
    -- this function, needs it for the k9_search_log audit row.
    local inventoryId, cooldownKey, plate

    if targetType == 'vehicle' then
        plate = GetVehicleNumberPlateText(entity)
        plate = plate and plate:match('^%s*(.-)%s*$') or nil -- trim GTA's space-padded plate string
        if not plate or plate == '' then
            return { ok = false, reason = 'invalid_target' }
        end
        -- Confirmed against the real overextended/ox_inventory source
        -- (contraband_search_contract.md §1): a vehicle trunk's inventory
        -- id is literally 'trunk' .. plate.
        inventoryId = ('trunk%s'):format(plate)
        cooldownKey = 'vehicle:' .. plate
    else
        -- A connected player's own inventory is keyed by their live
        -- numeric server id, already loaded while they're online — no
        -- lazy-load dance needed (unlike vehicles). Re-confirm the target
        -- is STILL connected right before deriving the inventory id (no
        -- yield has happened since the earlier resolution above, so this
        -- is a cheap belt-and-suspenders re-check, not a required
        -- TOCTOU close).
        if not targetServerId or GetPlayerPed(targetServerId) ~= entity then
            return { ok = false, reason = 'invalid_target' }
        end
        inventoryId = targetServerId
        cooldownKey = 'person:' .. citizenid -- citizenid, not raw netId/server id (security review §7 — survives a ped-recreation edge case)
    end

    -- Per-resolved-target cooldown check.
    local lastTargetAt = lastTargetSearchAt[cooldownKey]
    if lastTargetAt and (requestedAt - lastTargetAt) < Config.SearchZones.searchCooldownMs then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- Stamp BOTH cooldowns NOW, BEFORE the awaited ox_inventory call below.
    lastSearchAt[source] = requestedAt
    lastTargetSearchAt[cooldownKey] = requestedAt

    -- Query contents (recursively via SumContrabandWeight below), pcall-
    -- wrapped — a lazily-loaded vehicle inventory can error on edge-case
    -- vehicle classes/timing. LOAD-BEARING DETAIL, confirmed against the
    -- real overextended/ox_inventory source (contraband_search_contract.md
    -- §1, re-verified by tech-scout): for an uncached vehicle trunk,
    -- ox_inventory's own loadInventoryData awaits
    -- lib.callback.await('ox_inventory:getVehicleData', source, netid)
    -- against the ambient `source` of whatever coroutine is executing —
    -- and if that ambient `source` is nil (i.e. this call were deferred to
    -- a different tick/thread/helper outside this callback's own execution
    -- context), it falls back to `NetworkGetEntityOwner(entity)` instead of
    -- hard-failing. That fallback resolves UNPREDICTABLY to whoever
    -- currently holds network ownership of the vehicle (could be an
    -- unrelated bystander, or resolve to nobody useful for a vehicle
    -- nobody's near) — not the requesting K9 player. This call MUST
    -- therefore stay inside this callback's own execution context (the one
    -- FiveM already set `source` to = the requesting K9 player) so the
    -- lazy-load asks the correct client, not an arbitrary/unpredictable one.
    local queryOk, items = pcall(function()
        return exports.ox_inventory:GetInventoryItems(inventoryId)
    end)

    if not queryOk or items == nil then
        -- k9_search_log audit row — regression-tester correction: this
        -- MUST be wired at THIS specific pcall boundary (the one strictly
        -- around the ox_inventory read, which genuinely reached a real
        -- inventory-read attempt), NOT on the outer catch-all
        -- pcall(HandleSearchTarget, ...) in the callback registration
        -- below, which also catches early-validation errors (proximity,
        -- plate parsing, citizenid resolution) that never touched real
        -- inventory. Logging from that outer wrapper instead would record
        -- a phantom search that never actually happened whenever an
        -- unrelated future bug hits early validation, contradicting this
        -- table's own forensic-integrity purpose (sql/install.sql's scope
        -- comment: only found/clean/search_failed, never early rejections).
        -- 'search_failed' has no real totalWeight/alertTier to record
        -- (NULL, not 0/'clean' — never misrepresent a failed check as a
        -- clean one, same discipline as the callback's own reason value).
        LogSearchAttempt(source, targetType, plate, citizenid, 'search_failed', nil, nil)
        return { ok = false, reason = 'search_failed' } -- NEVER collapse into contrabandFound = false
    end

    local totalWeight = SumContrabandWeight(inventoryId, items, 1)
    local contrabandFound = totalWeight > 0
    local alertTier = ResolveAlertTier(totalWeight)

    if Config.Features.ContrabandAlerts and alertTier.alert ~= 'clean' then
        BroadcastContrabandAlert(GetEntityCoords(entity), targetNetId, alertTier.alert)
    end

    -- k9_search_log audit row (sql/install.sql — db-schema's Phase 2
    -- addition, wired here per that table's own integration note): one row
    -- per completed search attempt, fire-and-forget, never delays this
    -- return.
    LogSearchAttempt(source, targetType, plate, citizenid, contrabandFound and 'found' or 'clean', totalWeight, alertTier.alert)

    -- The requester who performed a real, gated, proximity-checked search
    -- learns the real number — this is the ONE place totalWeight is
    -- allowed to appear (security review §6). Applies identically when
    -- Config.Features.ContrabandAlerts == false (§11.5: that flag gates
    -- the broadcast above, not the requester's own result here).
    return {
        ok = true,
        contrabandFound = contrabandFound,
        totalWeight = totalWeight,
        alertTier = alertTier.alert,
    }
end

--- SPEC.md §11.4 item 2 / contraband_search_contract.md §3. THE
--- security-critical callback of Phase 2 (SPEC.md §11.1 sub-phase 2b).
lib.callback.register('qbx_k9unit:server:searchTarget', function(source, targetType, targetNetId)
    if type(targetType) ~= 'string' or (targetType ~= 'vehicle' and targetType ~= 'person') or type(targetNetId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' } -- defensive: never trust client payload shape
    end

    if not Config.Features.SearchZones then
        return { ok = false, reason = 'feature_disabled' } -- real server-side no-op regardless of client UI state
    end

    if not HasK9Access(source) then
        return { ok = false, reason = 'no_access' } -- reuse the global from server/certifications.lua, do not re-derive
    end

    if SearchInFlight[source] then
        return { ok = false, reason = 'search_in_progress' } -- reject outright, never queue/race a concurrent call from the same source
    end

    -- Set the in-flight mutex synchronously, BEFORE any further work that
    -- could yield (contraband_search_contract.md §4A) — cleared on EVERY
    -- exit path below.
    SearchInFlight[source] = true

    local requestedAt = GetGameTimer()

    -- Flat per-source cooldown (ANY target) — BLOCKING per
    -- contraband_search_security_review.md §2, not present in SPEC.md
    -- §11.4's original text (which only specified a per-(source, target)
    -- cooldown). Closes the "sweep every vehicle in a parking lot with
    -- zero delay" flood vector a per-pair-only cooldown leaves open.
    if lastSearchAt[source] and (requestedAt - lastSearchAt[source]) < Config.SearchZones.sniffAnimDurationMs then
        SearchInFlight[source] = nil
        return { ok = false, reason = 'on_cooldown' }
    end

    local ok, result = pcall(HandleSearchTarget, source, targetType, targetNetId, requestedAt)

    SearchInFlight[source] = nil -- ALWAYS clear, success or error (contraband_search_contract.md §4A "finally")

    if not ok then
        print(('[qbx_k9unit] searchTarget error for source %s: %s'):format(source, tostring(result)))
        return { ok = false, reason = 'search_failed' }
    end

    return result
end)

--- Cleans up this file's per-SOURCE ephemeral state on disconnect (does
--- NOT touch `lastTargetSearchAt`, which is intentionally NOT keyed by
--- source — see that table's own doc comment on why it needs an
--- independent TTL sweep instead).
AddEventHandler('playerDropped', function(_reason)
    local src = source
    SearchInFlight[src] = nil
    lastSearchAt[src] = nil
end)
