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

    ======================================================================
    CORRECTNESS PASS (coder-backend, this session) — three findings, all
    fixed below. Evidence and reasoning kept here rather than only in a
    commit message, per this file's own established documentation style.

    1. MAX-HEALTH AGREEMENT BETWEEN THE SERVER'S CLAMP AND THE CLIENT'S
       CLAMP — QA raised, this pass resolves it WITH EVIDENCE, not
       assumption:
       Grepped this entire resource for every native capable of changing a
       ped's REAL max-health ceiling (`SetPedMaxHealth`/`SET_PED_MAX_HEALTH`,
       any `SetEntityMaxHealth`-shaped call, any local assignment to a
       `maxHealth`/`healthMax` variable that is later written back to the
       entity rather than just read) — zero matches anywhere in this
       resource outside the two read-only `GetEntityMaxHealth` call sites
       already known (this file, and client/hud.lua's own read-only HUD
       normalization). server/wellbeing.lua's Injury stat — the "injury/
       wellbeing subsystem" the open question named — is CONFIRMED (read its
       real implementation directly this session) to be an entirely
       separate, virtual, per-citizenid float (`WellbeingStats[citizenid]
       .injury`, clamped 0..Config.Wellbeing.Injury.max) that never touches
       the ped's actual native health/max-health fields at all — `Config
       .K9Medkit.injuryRestore` restores THAT virtual stat via
       `RestoreInjury`, entirely independent of the `GetEntityMaxHealth`
       read three lines above it in HandleUseK9Medkit. So: nothing in this
       codebase ever modifies a K9 ped's real max health, meaning the
       server's `GetEntityMaxHealth(targetPed)` read (HandleUseK9Medkit,
       "compute" step) and the target's own client's later
       `GetEntityMaxHealth(ped)` read (client/medkit.lua's
       applyMedkitHeal) are two live reads of the SAME never-modified
       native value on the SAME entity — they cannot disagree from
       anything this resource does.
       That said, this file does not rely on "cannot disagree" as a excuse
       to skip a safety net for the one thing actually outside this
       resource's control: a THIRD-PARTY resource changing max health, or
       the target ped itself being swapped/respawned, in the network-latency
       gap between the server's compute-time read and the client's
       apply-time read. The client's own independent `GetEntityMaxHealth`
       clamp (client/medkit.lua, pre-existing, kept as-is) already covers
       this correctly by construction: it clamps the SERVER's number down to
       whatever the client's OWN live ceiling is at apply time, so any
       cross-owner drift can only ever produce a safe under-heal (capped to
       the lower of the two ceilings), never an overheal above the
       currently-live maximum. No code change was needed here — this is a
       documented resolution, not a fix.

    2. DEAD-K9 GATE (NEW, fixed below) — nothing previously stopped healing
       a K9 whose ped is already dead. This resource already has an
       established, reused answer for "should this interaction be usable on
       a dead target" — server/combat.lua's `ValidateCombatRequest`
       rejects a dead target by default via `IsEntityDead(targetPed)` with
       reason `'target_dead'`, and its own header explains why: a scripted
       laststand/EMS "dead" state is a DIFFERENT thing from a raw
       `SetEntityHealth` bump, and reviving a player is the job of that
       real laststand/EMS flow, never a side effect of an unrelated item.
       A K9 medkit is documented everywhere in this file as restoring an
       INJURED (alive) K9's health — it was never meant to be a revive
       item, and letting it push a dead K9's raw health back up via the
       exact same client-self-applied `SetEntityHealth` this file already
       flags as cross-owner-uncertain would let a plain consumable silently
       stand in for whatever this server's real ambulance/laststand system
       is supposed to gate revival behind, with none of that system's own
       rules (cooldowns, animations, item costs it may impose, etc.)
       applying. HandleUseK9Medkit now rejects with `'target_dead'` the
       same way ValidateCombatRequest already does, checked immediately
       after the model re-verification (cheap, non-mutating, so it runs
       before the mutex/cooldown/item-possession work below, same
       "cheapest checks first" discipline this file's function doc comment
       already establishes). client/medkit.lua's `applyMedkitHeal` also
       gained a matching `IsEntityDead` guard for the one case the
       server-side gate cannot see: the K9 dying from unrelated damage in
       the network-latency window between the server's decision and the
       client actually receiving and applying it — without that guard, a
       heal computed while the K9 was alive could still land as a
       de-facto revive a moment after they died. Both gates fail the SAME
       direction (reject/no-op), never the opposite.

       ADDENDUM (native-sweep follow-up pass, coder-backend): the
       server-side half of this finding, as originally written, DID NOT
       ACTUALLY WORK — `IsEntityDead` has no FXServer server implementation
       (see PED_DEAD_HEALTH_THRESHOLD's own doc comment below for the
       primary-source finding) and always returned `false` server-side, so
       HandleUseK9Medkit's reject below never fired regardless of the
       target's real state. server/combat.lua's `ValidateCombatRequest`,
       named above as the "established, reused answer" this gate was
       modeled on, had the identical bug at the same time. Both are now
       fixed to use `GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD`
       instead — see this file's own doc comment on `PED_DEAD_HEALTH_THRESHOLD`
       below for the full writeup. client/medkit.lua's client-side
       `applyMedkitHeal` guard (mentioned above) is UNAFFECTED by any of
       this: `IsEntityDead` is confirmed client-callable (only its
       server-side registration is missing), so that guard was, and
       remains, real.

    3. MUTEX RELEASE UNDER AN UNCAUGHT ERROR (NEW, fixed below) — the
       previous shape released `MedkitMutex` only via the `finish(result)`
       wrapper, meaning every one of THIS function's own `return` statements
       released it correctly, but a hypothetical uncaught Lua error thrown
       by any native call inside the mutex-held region (never observed, but
       structurally possible if a future edit adds one) would propagate
       straight past every `return finish(...)` site to the OUTER
       `lib.callback.register` pcall without ever calling `Release` —
       permanently locking that one citizenid out of ever being treated
       again for the lifetime of the resource (a genuine unbounded trap: no
       sweep/TTL touches a mutex entry, by design, per server/cooldowns.lua's
       own NewMutex doc comment — "a mutex is acquire/release, not a
       cooldown pretending to have no expiry"). Fixed by moving the entire
       mutex-held mutation body into its own function and wrapping ONLY that
       call in a `pcall` whose very next line unconditionally releases the
       mutex, so release is no longer contingent on every internal return
       path being enumerated correctly — see RunUseK9MedkitMutation below.
    ======================================================================
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

--- NATIVE-AVAILABILITY FIX (this pass, coder-backend, native-sweep
--- follow-up): the dead-K9 gate below (CORRECTNESS PASS finding 2 in this
--- file's own header) was written using `IsEntityDead`, which has NO
--- FXServer server implementation at all -- confirmed against the primary
--- source, not just the 404 on its `ext/native-decls` doc page. Traced
--- `citizenfx/fivem`'s own C++ native-registration list
--- (code/components/citizen-server-impl/src/state/ServerGameState_Scripting.cpp,
--- the exact file that implements every entity/ped-related native FXServer
--- DOES expose server-side): zero `RegisterNativeHandler` call for
--- `IS_ENTITY_DEAD` anywhere in it, or anywhere else in the repo (a
--- full-repo source search for the literal string `"IS_ENTITY_DEAD"`
--- returns zero matches) -- while `GET_ENTITY_HEALTH` (already used
--- elsewhere in this exact file, two lines below in
--- RunUseK9MedkitMutation) IS registered there. FXServer does not throw on
--- an unregistered native, it silently no-ops and never writes the result
--- buffer, so `IsEntityDead(targetPed)` in HandleUseK9Medkit ALWAYS
--- returned `false` -- meaning the dead-K9 gate this file's header
--- documents as "fixed below," and the CHANGELOG entry recording it as
--- closed, never actually worked: a dead K9's health could always be
--- pushed back up via this item, exactly the bug that gate was written to
--- close. Rewritten below to use `GetEntityHealth`, confirmed registered
--- and already relied on elsewhere in this file.
---
--- THRESHOLD: `PED_DEAD_HEALTH_THRESHOLD = 100`, matching
--- server/combat.lua's OWN identical fix and identical reasoning (see that
--- file's own doc comment on its own `PED_DEAD_HEALTH_THRESHOLD` constant
--- for the full writeup) -- restated briefly here since this file does not
--- share a module with combat.lua: GTA peds are conventionally declared
--- dead once health drops to (or below) 100, not 0 (the reason a ped's
--- default max health is 200, not 100 -- the bottom 100 points are the
--- "already dead" floor). Using `<= 0` here would make this check a
--- near-permanent no-op again (a K9 ped's health essentially never reaches
--- literal 0 before the engine already considers it dead at 100),
--- reproducing this exact bug while looking fixed. `<= 100` also does NOT
--- falsely reject a merely-badly-INJURED (alive) K9 -- a K9's real health
--- only drops that low when genuinely dying/dead, which is precisely the
--- case this gate exists to reject; an injured-but-alive K9 (the item's
--- actual intended target) sits well above this floor.
local PED_DEAD_HEALTH_THRESHOLD = 100

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

--- The mutex-HELD mutation body — everything from proximity through the
--- actual heal/Injury restore. Split out from HandleUseK9Medkit purely so
--- that function can `pcall` this one call and unconditionally release
--- MedkitMutex on the very next line regardless of outcome — see this
--- file's header, CORRECTNESS PASS finding 3, for why release must not
--- depend on every internal `return` path being enumerated correctly.
---
--- Validation order — cheapest/most-defensive checks first, mutating work
--- last, same discipline server/search.lua's HandleSearchTarget already
--- establishes for this codebase's security-critical files:
---   1. MANDATORY, FIRST-CLASS live proximity check between the USING
---      player's own live position and the TARGET's own live position —
---      never a client-claimed distance.
---   2. Per-target cooldown check.
---   3. Item possession check via GetItemCount — reject if the using
---      player doesn't actually carry the configured medkit item.
---   4. Stamp the cooldown NOW, before removing the item or healing
---      anything (TOCTOU-safe ordering discipline, mirrors
---      server/search.lua's "stamp before the awaited call" rule, applied
---      here even though neither ox_inventory call below yields today —
---      see this file's header).
---   5. Remove exactly one medkit item via RemoveItem — if this
---      unexpectedly fails despite step 3's check having just passed
---      (should not happen given neither call yields in between, but never
---      assumed), reject WITHOUT applying any health/Injury change. The
---      cooldown stamped in step 4 is not rolled back in this edge case —
---      an intentional, documented tradeoff, the same one
---      server/search.lua's own stamp-before-work ordering already accepts.
---   6. Compute the clamped new health value from a live
---      GetEntityHealth/GetEntityMaxHealth read and push it to the
---      target's own client to self-apply (see this file's header on why,
---      and CORRECTNESS PASS finding 1 for why this read can never
---      disagree with the target client's own later read).
---   7. Call RestoreInjury(citizenid, ...) if and only if server/wellbeing.lua
---      has defined it (forward-compatible no-op otherwise).
--- @param usingPed number
--- @param targetPed number
--- @param source number
--- @param targetServerId number
--- @param targetCitizenid string
--- @param requestedAt number
--- @return table result
local function RunUseK9MedkitMutation(usingPed, targetPed, source, targetServerId, targetCitizenid, requestedAt)
    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any
    -- ox_inventory query or state mutation, unconditionally. Without this,
    -- a modified client could supply the server id of ANY connected K9
    -- player anywhere on the map and heal/consume-item against them
    -- remotely — the same "map-wide oracle" risk
    -- contraband_search_contract.md §3 step 8 flags for search, applied
    -- here to a mutation instead of a read.
    local dist = #(GetEntityCoords(usingPed) - GetEntityCoords(targetPed))
    if dist > Config.K9Medkit.range then
        return { ok = false, reason = 'too_far' }
    end

    if MedkitCooldown.IsOnCooldown(targetCitizenid, Config.K9Medkit.cooldownMs, requestedAt) then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- Item possession check — cheap, non-mutating, run before the cooldown
    -- is stamped so a player with no medkit never burns the target's
    -- cooldown window for nothing.
    local carriedCount = exports.ox_inventory:GetItemCount(source, Config.K9Medkit.itemName)
    if not carriedCount or carriedCount < 1 then
        return { ok = false, reason = 'no_item' }
    end

    -- Stamp the cooldown NOW, before removing the item / healing anything
    -- below — see this function's own doc comment, step 4.
    MedkitCooldown.Touch(targetCitizenid, requestedAt)

    local removed = exports.ox_inventory:RemoveItem(source, Config.K9Medkit.itemName, 1)
    if not removed then
        -- Should not happen given the possession check above (neither
        -- ox_inventory call yields, per this file's header) — never
        -- treated as "item consumed" if this ever does fail.
        return { ok = false, reason = 'no_item' }
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

    NotifyPlayer(source, locale('medkit.treated_success'), 'success')
    if targetServerId ~= source then
        NotifyPlayer(targetServerId, locale('medkit.target_treated_notice'), 'inform')
    end

    return { ok = true }
end

--- Internal implementation for the useK9Medkit callback below. Called only
--- after the callback's own cheap checks (payload shape, feature flag,
--- IsMedkitUserAuthorized) already passed.
---
--- Cheap, non-mutating resolution/rejection checks live directly in this
--- function; the mutex-held mutation is delegated to
--- RunUseK9MedkitMutation above:
---   1. Resolve the USING player's own live ped — reject if unavailable.
---   2. Resolve `targetServerId` to a live, currently-connected player's
---      ped via GetPlayerPed (server-reliable, per this file's header) —
---      reject if it doesn't resolve to anyone online right now.
---   3. Re-derive the TARGET's REAL ped model server-side and confirm it's
---      a configured K9 model (IsConfiguredK9Model) — never trust that the
---      client's target selection actually was a K9.
---   4. Reject if the TARGET is already dead (GetEntityHealth <=
---      PED_DEAD_HEALTH_THRESHOLD, see that constant's own doc comment
---      above) — a K9 medkit
---      restores an INJURED, alive K9; it is not a revive item. See this
---      file's header, CORRECTNESS PASS finding 2, for why this must not
---      fall through to a real laststand/EMS system's own revive flow.
---   5. Resolve the target's citizenid — needed for the cooldown key and
---      the RestoreInjury accessor.
---   6. Acquire the per-target mutex — reject outright if already held
---      (another treat-K9 request for this exact K9 is in flight) —
---      release is GUARANTEED via the pcall below, not contingent on any
---      return path inside RunUseK9MedkitMutation.
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

    -- A medkit heals an INJURED, ALIVE K9 — never a dead one. See this
    -- file's header, CORRECTNESS PASS finding 2, AND the native-availability
    -- fix doc comment on PED_DEAD_HEALTH_THRESHOLD above (this check was
    -- `IsEntityDead(targetPed)`, which always silently returned false
    -- server-side -- this gate never actually worked until this pass).
    -- Mirrors server/combat.lua's own ValidateCombatRequest reject, same
    -- reason string ('target_dead'), same "cheap, non-mutating, checked
    -- before the mutex/cooldown/item work below" placement, same
    -- GetEntityHealth-based mechanism (also fixed there this pass).
    if GetEntityHealth(targetPed) <= PED_DEAD_HEALTH_THRESHOLD then
        return { ok = false, reason = 'target_dead' }
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not targetCitizenid then
        return { ok = false, reason = 'invalid_target' }
    end

    if not MedkitMutex.TryAcquire(targetCitizenid) then
        return { ok = false, reason = 'treatment_in_progress' }
    end

    -- GUARANTEED release — see this file's header, CORRECTNESS PASS
    -- finding 3. Release happens on the very next line after the pcall
    -- returns, regardless of whether RunUseK9MedkitMutation returned
    -- normally or threw, so a future edit that adds a fallible call inside
    -- the mutation body can never leak this citizenid's mutex entry.
    local ok, result = pcall(RunUseK9MedkitMutation, usingPed, targetPed, source, targetServerId, targetCitizenid, requestedAt)
    MedkitMutex.Release(targetCitizenid)

    if not ok then
        print(('[qbx_k9unit] useK9Medkit mutation error for source %s targeting citizenid %s: %s'):format(source, targetCitizenid, tostring(result)))
        return { ok = false, reason = 'medkit_failed' }
    end

    return result
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

    -- Purely a defensive outer net for anything thrown BEFORE
    -- HandleUseK9Medkit even reaches MedkitMutex.TryAcquire (e.g. a
    -- corrupted qbx_core player object inside GetPlayerPed/GetPlayer
    -- itself) — no mutex was ever acquired at that point, so there is
    -- nothing to release here. Once the mutex IS acquired,
    -- HandleUseK9Medkit's own inner pcall around RunUseK9MedkitMutation
    -- guarantees release unconditionally on the very next line (see this
    -- file's header, CORRECTNESS PASS finding 3) — this outer pcall never
    -- needs to reason about that mutex at all.
    local ok, result = pcall(HandleUseK9Medkit, source, targetServerId, requestedAt)
    if not ok then
        print(('[qbx_k9unit] useK9Medkit error for source %s: %s'):format(source, tostring(result)))
        return { ok = false, reason = 'medkit_failed' }
    end

    return result
end)
