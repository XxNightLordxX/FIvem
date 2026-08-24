--[[
    qbx_k9unit/server/medkit.lua

    Phase 4 implementation (coder-backend). Owns Config.Features.K9Medkit
    (PHASE4_SPEC.md §13.4.4): the `qbx_k9unit:server:useK9Medkit` callback —
    server-authoritative "use a medkit item on a nearby K9-model player"
    action. New, small file pair with client/medkit.lua, per PHASE4_SPEC.md
    §13.3's file plan ("real ox_inventory capability grant deserves the
    certification-file's level of scrutiny" — same reasoning
    server/search.lua's own header already gives for its trust-model split).

    SECURITY MODEL DELIBERATELY MIRRORS server/search.lua's already-reviewed
    pattern, per this task's explicit direction to reuse it as the template:
    proximity-before-mutation, target re-verification server-side (never
    trust a client-claimed entity/model — the target's REAL ped model is
    re-derived here via IsConfiguredK9Model, and the target must resolve to
    a currently-connected player, never an NPC), server-authoritative item
    consumption (the item is checked AND removed from the USING player's
    real ox_inventory server-side before any health change is applied — a
    client-reported "I used it" is never sufficient), and a TOCTOU-safe
    cooldown stamped BEFORE the mutating work, using server/cooldowns.lua's
    shared NewCooldown/NewMutex constructors (never a hand-rolled table,
    per REFACTOR_ROADMAP.md item 1's established convention).

    ======================================================================
    OX_INVENTORY EXPORT SIGNATURES — CONFIRMED AGAINST THE REAL SOURCE THIS
    SESSION (github.com/overextended/ox_inventory @ main, fetched and read
    directly, not remembered/guessed — same methodology
    phase2_notes/contraband_search_contract.md already used to confirm
    GetInventoryItems/GetContainerFromSlot for server/search.lua):
        exports.ox_inventory:GetItemCount(inv, itemName, metadata?, strict?) -> number
            (modules/inventory/server.lua, Inventory.GetItemCount, exported
            verbatim as 'GetItemCount')
        exports.ox_inventory:RemoveItem(inv, item, count, metadata?, slot?, ignoreTotal?, strict?) -> boolean success, string? response
            (modules/inventory/server.lua, Inventory.RemoveItem, exported
            verbatim as 'RemoveItem')
    Both resolve `inv` through ox_inventory's own internal `Inventory(inv)`
    helper, which accepts a connected player's own numeric server id
    directly — confirmed in the same source read, and exactly the same fact
    server/search.lua's own HandleSearchTarget already relies on for
    person-type searches ("a connected player's own inventory is keyed by
    their live numeric server id, already loaded while they're online — no
    lazy-load dance needed"). CONFIDENCE: HIGH — read directly from real
    ox_inventory source this session, not assumed from memory. Neither call
    yields/awaits internally (confirmed by reading both function bodies —
    no `.await`/`lib.callback.await` inside either), so unlike
    server/search.lua's `GetInventoryItems` (which CAN yield on an uncached
    vehicle trunk's lazy DB load), there is no genuine TOCTOU window
    between this file's cooldown/possession checks and its mutations — the
    cooldown is still stamped before the item is removed, purely to match
    this codebase's established discipline and to stay correct if a future
    ox_inventory version ever makes one of these calls yield.

    DELIBERATE DESIGN CHOICE — resolves PHASE4_SPEC.md §13.4.4 open
    question 2 (exact ox_inventory useable-item registration API) BY
    SIDESTEPPING IT rather than guessing at data/items.lua's
    client.export/server.export shape or the explicitly-`@deprecated`
    `Item(name, cb)` callback (confirmed deprecated in the real source read
    above — its own doc comment says "Use the 'ox_inventory:usedItem' event
    or the 'usingItem'/'buyItem' hooks" instead): this implementation does
    NOT register `k9_medkit` as a hotbar/UI "useable" item at all. It is a
    plain carried item, checked and consumed directly via the two confirmed
    exports above, triggered by an ox_target world interaction on the
    target K9 — the same "ox_target -> lib.callback -> server validates ->
    mutates state" shape already used everywhere else in this resource
    (leash, vehicle load/release, search), not ox_inventory's separate
    hotbar-use flow. This is a real implementation decision, not a
    workaround: it is MORE auditable than the hotbar-use event, since
    reading ox_inventory's real client flow this session confirmed that
    'ox_inventory:usedItem' fires with only (inventoryId, itemName, slot,
    metadata) — no interaction-target concept at all, so it could not carry
    "which K9 to heal" even if this file hooked it — and it needs no new
    data/items.lua wiring beyond a plain, non-special item definition.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4, K9Medkit only.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:useK9Medkit' (targetServerId: number)
       -> { ok: boolean, reason: string? }
       [THIS FILE] client/medkit.lua's "Treat K9" ox_target option.
       `targetServerId` is the K9 PLAYER's own server id (NOT a netId or
       entity handle) — client/medkit.lua resolves this via the standard,
       client-reliable NetworkGetPlayerIndexFromPed/GetPlayerServerId
       combo. That combo is safe CLIENT-side; server/search.lua's own
       header already flags that SAME combo as unverified SERVER-side,
       which is exactly why this file never calls it — it only ever calls
       GetPlayerPed(targetServerId) server-side, the same already-proven-
       server-reliable native server/search.lua's own
       ResolveConnectedPlayerFromPed already depends on.

    Server events (RegisterNetEvent, client->server): none — this feature
    is entirely request/response shaped, same posture as
    server/search.lua's searchTarget (there is no legitimate reason for a
    fire-and-forget "I healed my K9" event to exist).

    Client events (RegisterNetEvent, server->client):
    2. 'qbx_k9unit:client:applyMedkitHeal' (newHealth: number)
       [client/medkit.lua, TARGET K9 ONLY] — per PHASE4_SPEC.md §13.4.4's
       own open question 1: `SetEntityHealth`'s reliability when called
       server-side against a REMOTE-OWNED networked ped was not
       independently verified this session either way, so this file takes
       the spec's explicitly recommended, lower-risk path — the TARGET's
       OWN client self-applies the already-clamped ABSOLUTE health value
       this file computes from a live `GetEntityHealth`/`GetEntityMaxHealth`
       READ (reads are not the flagged uncertainty — only the cross-owner
       WRITE native is), mirroring every other "client self-applies to its
       own entity" pattern already established in this codebase (movement-
       rate modifiers, sprint/jump input blocks, PHASE4_SPEC.md §13.0
       Decision 3). The server still decides the real restored amount; the
       client only ever writes the exact number the server already computed
       and clamped — it cannot inflate or ignore the restore amount to gain
       anything, and never receives a raw "add N" delta it could reapply
       repeatedly.

    Commands: none. Automatic path: none.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Does NOT call `HasK9Access` — eligibility to USE a medkit ON a K9 is
      job-only (Config.Departments or Config.K9Medkit.emsJobs, or the
      optional override hook), deliberately NOT gated on the USING player's
      own K9 certification: treating a K9 is not itself a K9-handling
      action (an EMS medic with zero K9 certification is exactly the
      intended default use case per Config.K9Medkit.emsJobs). See
      IsMedkitUserAuthorized's own doc comment below.
    - Calls `IsConfiguredK9Model(modelHash)`, resource-global from
      server/certifications.lua — reused, never re-derived, to verify the
      TARGET really is a configured K9 model server-side.
    - Calls `RestoreInjury(citizenid, amount)`, resource-global from
      server/wellbeing.lua, ONLY IF THAT FUNCTION EXISTS
      (`type(RestoreInjury) == 'function'` guard) — server/wellbeing.lua
      (PHASE4_SPEC.md §13.1 sub-phase 4c/4d, the Injury wellbeing stat)
      has NOT been implemented as of this file being written (confirmed:
      no such file exists in this resource's server/ directory at the time
      of this pass — PHASE4_SPEC.md §13.1 itself documents K9Medkit, 4g, as
      depending on 4c/4d landing first). This is forward-compatible by
      design: once server/wellbeing.lua ships that accessor, this line
      activates with zero change needed here. Until then, K9Medkit restores
      REAL ped health only — never silently errors, and never blocks the
      health restore on a not-yet-built subsystem.
    - Owns `MedkitCooldown` and `MedkitMutex` below as file-local state,
      each a server/cooldowns.lua tracker instance (NewCooldown/NewMutex)
      — REFACTOR_ROADMAP.md item 1's convention, no hand-rolled table.
    - Exposes NO resource-global functions of its own.
]]

-- Precomputed set of configured EMS job names, built once at file load —
-- same "O(1) membership test, built once" convention
-- server/search.lua's ContrabandItemSet already establishes.
local EmsJobSet = {}
for _, jobName in ipairs(Config.K9Medkit.emsJobs or {}) do
    EmsJobSet[jobName] = true
end

-- Per-target (K9 citizenid) cooldown backing Config.K9Medkit.cooldownMs —
-- keyed on the TARGET'S resolved, stable citizenid (never the raw,
-- recyclable/spoofable-adjacent client-supplied targetServerId), same
-- "resolved identity, not a raw session id" discipline
-- server/search.lua's TargetSearchCooldown already established for its
-- own per-target cooldown. Outlives any single connection (a K9 that
-- disconnects and reconnects should not get a free early re-heal), so it
-- needs its own independent TTL sweep rather than playerDropped-based
-- cleanup — mirrors server/search.lua's TargetSearchCooldown exactly.
local MedkitCooldown = NewCooldown()

local MEDKIT_COOLDOWN_PRUNE_INTERVAL_MS = 60000
MedkitCooldown.StartSweep(MEDKIT_COOLDOWN_PRUNE_INTERVAL_MS, function(now, loggedAt)
    local staleAfterMs = Config.K9Medkit.cooldownMs * 2
    return (now - loggedAt) > staleAfterMs
end)

-- Per-target (K9 citizenid) mutex — prevents two concurrent
-- 'qbx_k9unit:server:useK9Medkit' calls (e.g. two medics treating the same
-- K9 at the same instant) from both passing the possession/cooldown checks
-- before either has consumed an item, which would double-count the heal
-- for the cost of one item on a genuinely racing pair of requests. Belt-
-- and-suspenders alongside the cooldown stamp below (this handler never
-- actually yields — see this file's OX_INVENTORY EXPORT SIGNATURES note —
-- so the two calls cannot truly interleave mid-handler today, but the
-- mutex keeps this file correct if a future change, e.g. an awaited audit
-- log write or RestoreInjury growing a DB round-trip, ever introduces a
-- real yield point here). Released on EVERY exit path, mirroring
-- server/search.lua's SearchMutex discipline exactly.
local MedkitMutex = NewMutex()

--- Server-authoritative eligibility check for the USING player: does
--- `source` hold a job allowed to use a K9 medkit? Deliberately NOT
--- HasK9Access — see this file's header FILE-TO-FILE CONTRACT note.
--- @param source number
--- @return boolean
local function IsMedkitUserAuthorized(source)
    local Player = exports.qbx_core:GetPlayer(source)
    local job = Player and Player.PlayerData and Player.PlayerData.job
    if not job or not job.name then return false end

    if Config.Departments[job.name] or EmsJobSet[job.name] then
        return true
    end

    -- Optional forward-looking override hook (PHASE4_SPEC.md §13.4.4 open
    -- question 3) — pcall-wrapped so a misbehaving server-owner-supplied
    -- function can never crash this callback; a thrown error is treated as
    -- "not authorized", never as "authorized" (fail closed).
    if type(Config.K9Medkit.IsMedkitUserAuthorizedOverride) == 'function' then
        local ok, result = pcall(Config.K9Medkit.IsMedkitUserAuthorizedOverride, source)
        return ok and result == true
    end

    return false
end

-- NotifyPlayer used to be defined here as its own local copy (one of 12
-- independent hand-rolled copies found by REFACTOR_ROADMAP.md's dedup
-- audit). It is now server/notify.lua's single shared resource-global
-- implementation -- see that file's own header for the extraction writeup.
-- Every call site below is unchanged: this file never passed a custom
-- title, which is server/notify.lua's own default.

--- Internal implementation for the useK9Medkit callback below. Called only
--- after the callback's own cheap checks (payload shape, feature flag,
--- IsMedkitUserAuthorized) already passed.
---
--- Validation order — cheapest/most-defensive checks first, mutating work
--- last, same discipline server/search.lua's HandleSearchTarget already
--- establishes for this codebase's security-critical files:
---   1. Resolve the USING player's own live ped — reject if unavailable.
---   2. Resolve `targetServerId` to a live, currently-connected player's
---      ped via GetPlayerPed (server-reliable, per this file's header) —
---      reject if it doesn't resolve to anyone online right now.
---   3. Re-derive the TARGET's REAL ped model server-side and confirm it's
---      a configured K9 model (IsConfiguredK9Model) — never trust that the
---      client's target selection actually was a K9.
---   4. Resolve the target's citizenid — needed for the cooldown key and
---      the RestoreInjury accessor.
---   5. Acquire the per-target mutex — reject outright if already held
---      (another treat-K9 request for this exact K9 is in flight).
---   6. MANDATORY, FIRST-CLASS live proximity check between the USING
---      player's own live position and the TARGET's own live position —
---      never a client-claimed distance.
---   7. Per-target cooldown check.
---   8. Item possession check via GetItemCount — reject if the using
---      player doesn't actually carry the configured medkit item.
---   9. Stamp the cooldown NOW, before removing the item or healing
---      anything (TOCTOU-safe ordering discipline, mirrors
---      server/search.lua's "stamp before the awaited call" rule, applied
---      here even though neither ox_inventory call below yields today —
---      see this file's header).
---  10. Remove exactly one medkit item via RemoveItem — if this
---      unexpectedly fails despite step 8's check having just passed
---      (should not happen given neither call yields in between, but never
---      assumed), reject WITHOUT applying any health/Injury change. The
---      cooldown stamped in step 9 is not rolled back in this edge case —
---      an intentional, documented tradeoff, the same one
---      server/search.lua's own stamp-before-work ordering already accepts.
---  11. Compute the clamped new health value from a live
---      GetEntityHealth/GetEntityMaxHealth read and push it to the
---      target's own client to self-apply (see this file's header on why).
---  12. Call RestoreInjury(citizenid, ...) if and only if server/wellbeing.lua
---      has defined it (forward-compatible no-op otherwise).
--- @param source number
--- @param targetServerId number
--- @param requestedAt number
--- @return table result
local function HandleUseK9Medkit(source, targetServerId, requestedAt)
    local usingPed = GetPlayerPed(source)
    if usingPed == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    -- GetPlayerPed on a bogus/offline/out-of-range server id returns 0 —
    -- the same server-reliable resolution primitive server/search.lua's
    -- own ResolveConnectedPlayerFromPed relies on, applied here directly
    -- since the client already supplies a server id rather than a netId
    -- needing entity resolution (see this file's header, callback contract
    -- item 1).
    local targetPed = GetPlayerPed(targetServerId)
    if targetPed == 0 or targetPed == usingPed then
        return { ok = false, reason = 'invalid_target' }
    end

    -- Re-derive the TARGET's REAL model server-side — never trust that the
    -- client's ox_target selection was actually a K9.
    if not IsConfiguredK9Model(GetEntityModel(targetPed)) then
        return { ok = false, reason = 'invalid_target' }
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not targetCitizenid then
        return { ok = false, reason = 'invalid_target' }
    end

    if not MedkitMutex.TryAcquire(targetCitizenid) then
        return { ok = false, reason = 'treatment_in_progress' }
    end

    -- Every remaining exit path below MUST release this mutex — do not add
    -- a new early `return` beneath this point without also releasing it.
    local function finish(result)
        MedkitMutex.Release(targetCitizenid)
        return result
    end

    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any
    -- ox_inventory query or state mutation, unconditionally. Without this,
    -- a modified client could supply the server id of ANY connected K9
    -- player anywhere on the map and heal/consume-item against them
    -- remotely — the same "map-wide oracle" risk
    -- contraband_search_contract.md §3 step 8 flags for search, applied
    -- here to a mutation instead of a read.
    local dist = #(GetEntityCoords(usingPed) - GetEntityCoords(targetPed))
    if dist > Config.K9Medkit.range then
        return finish({ ok = false, reason = 'too_far' })
    end

    if MedkitCooldown.IsOnCooldown(targetCitizenid, Config.K9Medkit.cooldownMs, requestedAt) then
        return finish({ ok = false, reason = 'on_cooldown' })
    end

    -- Item possession check — cheap, non-mutating, run before the cooldown
    -- is stamped so a player with no medkit never burns the target's
    -- cooldown window for nothing.
    local carriedCount = exports.ox_inventory:GetItemCount(source, Config.K9Medkit.itemName)
    if not carriedCount or carriedCount < 1 then
        return finish({ ok = false, reason = 'no_item' })
    end

    -- Stamp the cooldown NOW, before removing the item / healing anything
    -- below — see this function's own doc comment, step 9.
    MedkitCooldown.Touch(targetCitizenid, requestedAt)

    local removed = exports.ox_inventory:RemoveItem(source, Config.K9Medkit.itemName, 1)
    if not removed then
        -- Should not happen given the possession check above (neither
        -- ox_inventory call yields, per this file's header) — never
        -- treated as "item consumed" if this ever does fail.
        return finish({ ok = false, reason = 'no_item' })
    end

    -- Server-authoritative clamp: reads are not the flagged
    -- SetEntityHealth-reliability uncertainty (see this file's header) —
    -- only the WRITE, which happens on the target's OWN client below.
    local currentHealth = GetEntityHealth(targetPed)
    local maxHealth = GetEntityMaxHealth(targetPed)
    local newHealth = math.min(currentHealth + Config.K9Medkit.healthRestore, maxHealth)
    -- Never move health downward from whatever it currently is, even if a
    -- future config value were ever negative by mistake.
    newHealth = math.max(newHealth, currentHealth)

    TriggerClientEvent('qbx_k9unit:client:applyMedkitHeal', targetServerId, newHealth)

    -- Forward-compatible no-op until server/wellbeing.lua (PHASE4_SPEC.md
    -- §13.1 sub-phase 4c/4d) ships RestoreInjury — see this file's header.
    if type(RestoreInjury) == 'function' then
        local ok = pcall(RestoreInjury, targetCitizenid, Config.K9Medkit.injuryRestore)
        if not ok then
            print(('[qbx_k9unit] RestoreInjury errored for citizenid %s during K9Medkit use — health restore already applied, Injury restore skipped'):format(targetCitizenid))
        end
    end

    NotifyPlayer(source, 'K9 treated.', 'success')
    if targetServerId ~= source then
        NotifyPlayer(targetServerId, 'Your K9 has been treated.', 'inform')
    end

    return finish({ ok = true })
end

--- PHASE4_SPEC.md §13.4.4. Server-authoritative "use a K9 medkit" callback.
lib.callback.register('qbx_k9unit:server:useK9Medkit', function(source, targetServerId)
    if type(targetServerId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' } -- defensive: never trust client payload shape
    end

    if not Config.Features.K9Medkit then
        return { ok = false, reason = 'feature_disabled' } -- real server-side no-op regardless of client UI state
    end

    if not IsMedkitUserAuthorized(source) then
        return { ok = false, reason = 'no_access' }
    end

    local requestedAt = GetGameTimer()

    local ok, result = pcall(HandleUseK9Medkit, source, targetServerId, requestedAt)
    if not ok then
        print(('[qbx_k9unit] useK9Medkit error for source %s: %s'):format(source, tostring(result)))
        -- HandleUseK9Medkit's own `finish` wrapper releases MedkitMutex on
        -- every path it reaches — but if the error was thrown BEFORE that
        -- wrapper was even created (e.g. inside GetPlayerPed itself), no
        -- mutex was ever acquired for this call, so there's nothing to
        -- release here. TryAcquire's own key is the TARGET's citizenid,
        -- resolved partway through HandleUseK9Medkit, so this outer catch
        -- has no reliable key to release against defensively — documented
        -- as a known, narrow edge case rather than silently assumed safe:
        -- a genuinely thrown error that early would have to originate from
        -- a corrupted qbx_core player object, not from anything this file
        -- controls.
        return { ok = false, reason = 'medkit_failed' }
    end

    return result
end)
