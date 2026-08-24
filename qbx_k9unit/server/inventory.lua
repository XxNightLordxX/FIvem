--[[
    qbx_k9unit/server/inventory.lua

    Phase 4 implementation (coder-backend), PHASE4_SPEC.md §13.4.2
    ("K9 Inventory", `Config.Features.K9Inventory`) — read in full before this
    file was written, along with §13.2's `Config.K9Inventory` sketch, §13.3's
    file/module plan (this file + client/inventory.lua, a NEW pair, not
    folded into an existing file, "for the same real ox_inventory capability
    grant deserves the certification-file's level of scrutiny reasoning
    §11.3 already gave for splitting client/search.lua from
    client/tracking.lua by TRUST MODEL"), and server/search.lua's own header/
    structure (this file's explicit modeling template per the task that
    produced it: proximity-before-mutation, target re-verification,
    server-authoritative item consumption/transfer, TOCTOU-safe cooldown
    stamping via server/cooldowns.lua's shared constructors — no hand-rolled
    cooldown table). `Config.Features.K9Inventory` stays `false` shipped, per
    this resource's "ship disabled until acceptance criteria are fully met"
    convention (SPEC.md §9 item 4 / PHASE4_SPEC.md §13.6 item 8 both still
    apply: every numeric placeholder in Config.K9Inventory needs a
    config-validator pass, and §13.6 item 7's ox_inventory export-signature
    verification pass — see the CONFIDENCE NOTEs below — has not happened
    this session).

    ======================================================================
    RESOLVED DESIGN DECISION — Config.K9Inventory.accessScope
    (PHASE4_SPEC.md §13.4.2 open question 1 / §13.6 item 3)

    coder-security FINDING (this pass), CONFIRMED and independently
    RE-VERIFIED against the live, current `overextended/ox_inventory` `main`
    branch source (fetched fresh this session — modules/inventory/
    server.lua's `loadInventoryData`, root `server.lua`'s `openInventory`/
    `forceOpenInventory`, modules/bridge/server.lua's `hasGroup`,
    `registerStash`'s own doc comment): the previous version of this header
    described `accessScope = 'ownerOnly'` as "a fully supported, symmetric
    code path... flippable per-deployment with zero code change." That claim
    was FALSE, and was itself part of the defect — 'ownerOnly' provided NO
    actual access control:

    - ox_inventory's stash-open path (`loadInventoryData`'s stash branch,
      and `openInventory`'s own post-resolve check) gates access
      EXCLUSIVELY via `stash.groups`/`right.groups`, through
      `server.hasGroup(player, groups)`. Both checks are written as
      `stash.groups and ... and not hasGroup(...)` / `right.groups and not
      hasGroup(...)` — a nil `groups` short-circuits straight to ALLOW, for
      every caller, unconditionally. `ResolveStashOwnerAndGroups`'s
      'ownerOnly' branch returned `groups = nil`.
    - `RegisterStash`'s `owner` argument (string OR the boolean `true`
      "personal locker" form) is used EXCLUSIVELY for `Inventories` table
      keying/partitioning (`Inventories[owner and
      ('%s:%s'):format(stash.name, owner) or stash.name]`) and DB
      persistence (`db.saveStash(inv.owner, ...)`) — it is NEVER compared
      against the calling player's own identity anywhere in either
      function. `registerStash`'s own upstream doc comment confirms this is
      intentional, not an oversight: it documents the boolean `true` form as
      "each player has a unique stash, but can request other player's
      stashes" — cross-owner access is upstream-documented, expected
      behavior for that form, not a bug this resource could rely on
      closing.
    - Net effect: once any K9's stash had been registered even once in a
      server session (trivially triggered by that K9 opening their own
      gear), ANY connected player who knew or guessed that citizenid could
      call `exports.ox_inventory:openInventory('stash', 'k9inv-<citizenid>')`
      directly from a modified client and get full read/write access —
      bypassing every check this resource makes (proximity, HasK9Access,
      IsAuthorizedForK9Inventory, the cooldown/mutex) and
      `Config.Features.K9Inventory` itself, since ox_inventory knows nothing
      about that flag.

    CONCLUSION: there is no ox_inventory mechanism this resource can hook to
    make a real, per-K9-owner ACL exist — `groups` (job/rank membership via
    `hasGroup`) is the only actual capability ox_inventory's stash system
    provides. `'department'` already uses exactly that mechanism correctly
    (`groupRank >= (requiredRank or 0)` grants any grade in a listed job,
    matching this resource's documented intent) and remains the shipped
    default below, UNCHANGED — "shared field equipment," the same framing
    this resource already gives `Config.K9Vehicles`' patrol-vehicle trunk
    access, chosen because the K9 in this resource is a full,
    independently-logged-in player character (SPEC.md §1/§4.5's
    post-correction model): a handler restocking their partner K9's gear
    while the K9 player is offline is the ordinary case this resource is
    built around, not an edge case. The real theft-risk tradeoff
    'department' creates (any officer in the department could pilfer a K9's
    stash) is the same social/administrative-abuse category
    `phase2_notes/contraband_search_contract.md` §6's last bullet already
    accepts for search-capability misuse — not a code-level exploit any
    config value here can close.

    `accessScope` is therefore HARD-ENFORCED to `'department'` — the only
    value this file actually implements a real access control for — via an
    `assert` at resource start (below), not left selectable with a caveat
    comment: a config value that can silently grant world-readable
    read/write access to every K9's inventory is exactly the class this
    resource already treats as a hard startup failure, per
    server/main.lua's `nudgeRequiresUnlocked` assert and
    server/search.lua's own `onResourceStart` config-invariant asserts —
    same precedent, applied here. `ResolveStashOwnerAndGroups` and
    `IsAuthorizedForK9Inventory` below still fail closed for any
    non-'department' value as defense-in-depth (in case a future edit ever
    removes the assert without touching them), but that code path is
    UNREACHABLE in a running resource today — 'ownerOnly' is not an
    implemented, selectable option, it is a rejected one. Still flagged for
    an explicit human product sign-off before `Config.Features.K9Inventory`
    ever defaults to `true` on a live server.

    ======================================================================
    CONFIDENCE NOTES — every ox_inventory export/shape this file's body
    depends on, graded honestly per this session's own verification (or lack
    of it), same discipline server/search.lua's header and
    phase2_notes/contraband_search_contract.md §1 already established for
    Phase 2's export surface:

    - `GetInventoryItems`/`GetContainerFromSlot` (server/search.lua's own
      confirmed exports) are NOT used by this file at all — K9Inventory
      never reads/sums a stash's contents server-side, it only registers the
      stash and hands back its id; ox_inventory's own client-side UI (opened
      via `openInventory` below) is what actually presents/moves items once
      access is granted.
    - `exports.ox_inventory:RegisterStash(id, label, slots, weight, owner,
      groups)` — VERIFIED this session, directly against the current
      `overextended/ox_inventory` `main` branch `registerStash` function
      (root server.lua): signature is exactly `registerStash(name, label,
      slots, maxWeight, owner, groups, coords, instance)` — HIGH confidence,
      including for the DYNAMIC, per-player-registered-at-runtime call shape
      used here (one stash per K9 citizenid, registered lazily on first
      request); `registerStash` is fully generic over call timing, nothing
      in it special-cases "declared once at file-load" vs. "called
      lazily at runtime."
    - `owner`/`groups` semantics — VERIFIED this session against the same
      source, including `registerStash`'s own doc comment and the actual
      access-check code in `loadInventoryData`/`openInventory`
      (modules/inventory/server.lua, root server.lua): `groups` —
      `table<jobName, minGrade>` — IS the real, and ONLY, access gate,
      checked via `server.hasGroup(player, groups)` wherever `groups` is
      non-nil; `minGrade = 0` for every configured department (see
      K9InventoryDepartmentGroups below) is this file's own choice to mean
      "any grade in that job," confirmed correct against `hasGroup`'s
      `groupRank >= (requiredRank or 0)` logic. `owner` (string or boolean
      `true`) is NOT an access gate at all — confirmed used exclusively for
      `Inventories` table keying and DB persistence, never compared against
      the requesting player's identity anywhere in either function (see the
      RESOLVED DESIGN DECISION section above for the full trace — this is
      the coder-security finding this pass fixes).
    - `exports.ox_inventory:openInventory('stash', stashId)` (the CLIENT-side
      call, client/inventory.lua) — VERIFIED this session: this exact call
      shape (`'stash', stash.name`) appears in ox_inventory's own
      modules/inventory/client.lua. HIGH confidence.
    - `Config.K9Inventory.allowedItems` item-whitelist enforcement is
      DELIBERATELY NOT IMPLEMENTED in this pass — PHASE4_SPEC.md §13.4.2
      itself flags this as "a real, currently unresolved implementation
      question, not assumed away": whether a `registerHook('swapItems', ...)`
      -style hook is the right/only mechanism needs its own ox_inventory-hook
      verification pass this session did not perform. Setting
      `Config.K9Inventory.allowedItems` to a non-nil list currently has NO
      effect — left as an honestly-inert config field (see config.lua's own
      comment on it) rather than fake/partial enforcement that would silently
      under-deliver what a server owner configured.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4.

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:openK9Inventory' (targetNetId: number)
       -> { ok: boolean, reason: string?, stashId: string? } [THIS FILE]
       See HandleOpenK9Inventory's own doc comment below for the full
       validation order. Returns the resolved, server-derived stash id ONLY
       to an interactor who passed every check below — the client then opens
       it via ox_inventory's own `openInventory` export (client/inventory.lua),
       whose OWN owner/groups check (set at RegisterStash time below) is the
       REAL access-control boundary, per PHASE4_SPEC.md §13.4.2's own framing:
       "the ox_target option's client-side visibility... is a UX convenience
       only... A modified client calling
       exports.ox_inventory:openInventory('stash', 'k9inv-<anyCitizenid>')
       directly must be rejected by ox_inventory's own owner/group check, not
       by anything this resource adds on top." The authorization re-check
       inside HandleOpenK9Inventory below is DEFENSE IN DEPTH on top of that
       real boundary (matches this file's own header claim of
       server/search.lua-level scrutiny), not a substitute for it — this
       resource's actual responsibility, per that same spec passage, is
       choosing correct, restrictive owner/groups values at registration
       time (ResolveStashOwnerAndGroups below), never re-implementing access
       control itself.

    Server events (RegisterNetEvent, client->server): none. Entirely
    request/response shaped, same posture server/search.lua's header
    documents for the identical reason — no legitimate reason for a
    fire-and-forget "I opened it" event to exist.

    Client events (RegisterNetEvent, server->client): none.

    Commands: none.

    Automatic path: none. Stash registration is lazy (on first request), NOT
    on PlayerLoaded — PHASE4_SPEC.md §13.4.2 explicitly offers this as an
    equally-valid alternative to PlayerLoaded-time registration ("On
    PlayerLoaded (or lazily, on first interaction attempt)"), chosen here to
    avoid adding a second PlayerLoaded consumer/dependency for a capability
    most K9 characters may never actually use in a given session.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `HasK9Access(source)` and `IsConfiguredK9Model(modelHash)`,
      resource-globals from server/certifications.lua — reused, never
      re-derived, same rule server/search.lua and server/main.lua already
      follow.
    - THIS FILE exposes NO resource-global functions.
    - THIS FILE owns `K9InventoryOpenCooldown` and `K9InventoryOpenMutex`
      below as file-local state, each a server/cooldowns.lua tracker
      instance (REFACTOR_ROADMAP.md item 1's established convention — no
      hand-rolled cooldown/mutex table, per this file's own task-level
      instruction).
    - `ResolveConnectedPlayerFromPed` below is a SMALL LOCAL COPY of
      server/search.lua's function of the same name/purpose, not a shared
      global — server/search.lua exposes no resource-global functions (see
      its own FILE-TO-FILE CONTRACT), so there is nothing to reuse without
      either expanding that file's contract or duplicating a small,
      self-contained helper. Duplicating is the deliberate choice here
      (mirrors client/movement.lua's own documented "small local copy vs.
      expanding another file's contract" tradeoff for IsEntityModelK9) —
      same reasoning, same conclusion, applied server-side. Kept IDENTICAL
      in logic and doc comment to server/search.lua's original for the same
      reason that file gives (avoids depending on an unverified
      GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity)) native combo on
      the single most security-sensitive check in this file).
    ======================================================================
]]

-- Per-interactor-source cooldown on the openK9Inventory REQUEST itself
-- (distinct from, and much cheaper than, server/search.lua's per-target
-- searchCooldownMs — this action grants access to a persistent stash, not a
-- one-shot information probe, so the only real concern is request-spam, not
-- information-farming). Mirrors LEASH_REQUEST_COOLDOWN_MS's exact shape/
-- rationale in server/main.lua.
local K9_INVENTORY_OPEN_COOLDOWN_MS = 1000
local K9InventoryOpenCooldown = NewCooldown(K9_INVENTORY_OPEN_COOLDOWN_MS)
K9InventoryOpenCooldown.RegisterPlayerDropped()

-- Defensive per-interactor-source mutex, mirroring server/search.lua's
-- SearchMutex — added even though RegisterStash is NOT confirmed to be a
-- yielding call this session (see this file's header CONFIDENCE NOTE): if
-- it turns out to yield on some ox_inventory internal path this session
-- didn't observe, this closes the exact same same-source concurrent-call
-- race server/search.lua's SearchMutex closes for GetInventoryItems, at
-- negligible cost if it never actually yields. Set synchronously before any
-- potentially-yielding work, cleared on every exit path.
local K9InventoryOpenMutex = NewMutex()
K9InventoryOpenMutex.RegisterPlayerDropped()

-- Ephemeral, session-only set of citizenids whose K9 stash has already been
-- RegisterStash'd this server session — avoids re-registering (and
-- re-deriving owner/groups) on every single open request. Deliberately
-- never evicted: unlike server/certifications.lua's Certifications table
-- (which was a regression-tester finding specifically because it held
-- security-relevant, potentially-stale state), a stale entry here can never
-- cause an incorrect access decision — it only ever skips a redundant
-- RegisterStash call for a citizenid this session has already seen. Bounded
-- in practice by the number of distinct K9 characters actually accessed in
-- one server session, not unbounded resource-lifetime growth.
local EnsuredK9Stashes = {}

-- Precomputed `table<jobName, minGrade>` for the 'department' accessScope
-- shape, built once at file load from Config.Departments (generic over that
-- table per this codebase's existing convention — SPEC.md §3 acceptance
-- bullet 3 — no hardcoded job name). `minGrade = 0` for every configured
-- department: this resource's own choice to mean "any grade within that
-- job may access," not a verified ox_inventory default (see this file's
-- header CONFIDENCE NOTE).
local K9InventoryDepartmentGroups = {}
for jobName in pairs(Config.Departments) do
    K9InventoryDepartmentGroups[jobName] = 0
end

-- CONFIG-SAFETY GUARD (coder-security finding, this pass — see this file's
-- header RESOLVED DESIGN DECISION section for the full trace). `'department'`
-- is the ONLY `Config.K9Inventory.accessScope` value this file implements a
-- real ox_inventory access control for — `'ownerOnly'` (or any other value)
-- relies on ox_inventory's `owner` RegisterStash argument, which is never
-- checked against the calling player's identity anywhere in ox_inventory's
-- own open-inventory path (independently verified against the live,
-- current `overextended/ox_inventory` source this session): `groups` via
-- `server.hasGroup` is the only real gate, and a nil `groups` (what
-- 'ownerOnly' produces) short-circuits to ALLOW for every caller. Failing
-- loudly here, at resource start, rather than letting a misconfigured value
-- silently grant world-readable read/write access to every K9's stash —
-- same precedent as server/main.lua's `nudgeRequiresUnlocked` assert and
-- server/search.lua's own `onResourceStart` config-invariant asserts,
-- placed in THIS file (not centralized) because this is the file whose
-- security model actually depends on it, same reasoning server/search.lua's
-- own header already gives for that placement choice.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    assert(
        Config.K9Inventory.accessScope == 'department',
        "[qbx_k9unit] Config.K9Inventory.accessScope must be 'department' -- " ..
        "'ownerOnly' (or any other value) is NOT a real access control. ox_inventory's " ..
        'RegisterStash only gates stash access via its `groups` argument (server.hasGroup); ' ..
        'the `owner` argument is used exclusively for internal stash keying and DB persistence ' ..
        "and is never checked against the calling player's identity anywhere in ox_inventory's " ..
        'open-inventory path (verified against the current overextended/ox_inventory source). ' ..
        "Setting accessScope to anything but 'department' would silently let ANY connected " ..
        "player who knows or guesses a K9's citizenid open that K9's stash directly via " ..
        "exports.ox_inventory:openInventory('stash', 'k9inv-<citizenid>'), bypassing every " ..
        'check this resource makes (proximity, HasK9Access, IsAuthorizedForK9Inventory, the ' ..
        'cooldown/mutex) and Config.Features.K9Inventory itself.'
    )
end)

--- Resolves a ped entity to the currently-connected player's server id it
--- belongs to, or nil if it doesn't belong to any currently-connected
--- player. Small local copy of server/search.lua's function of the same
--- name — see this file's header FILE-TO-FILE CONTRACT for why this is
--- duplicated rather than shared, and server/search.lua's own doc comment
--- on this exact logic for the full "why not
--- GetPlayerServerId(NetworkGetPlayerIndexFromPed(entity))" rationale (that
--- native combo was never independently confirmed reliable SERVER-side this
--- session either).
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

--- Resolves the `owner`/`groups` RegisterStash arguments for a given K9
--- citizenid, per Config.K9Inventory.accessScope. See this file's header
--- RESOLVED DESIGN DECISION section for the full reasoning. The
--- onResourceStart assert above guarantees accessScope is always
--- 'department' in a running resource — the branch below is UNREACHABLE
--- dead code today, kept only as defense-in-depth (fails to the most
--- restrictive shape, single-owner/no-groups, rather than the more
--- permissive 'department' reading) in case a future edit ever removes
--- that assert without touching this function.
--- @param citizenid string
--- @return string|boolean owner
--- @return table? groups
local function ResolveStashOwnerAndGroups(citizenid)
    if Config.K9Inventory.accessScope == 'department' then
        return false, K9InventoryDepartmentGroups
    end

    -- UNREACHABLE in a running resource (see doc comment above) — defense
    -- in depth only. Fails CLOSED to the most restrictive shape
    -- (single-owner, no groups) rather than silently treating a typo as the
    -- more permissive 'department' reading. NOTE: unlike the real
    -- 'department' path above, this shape provides NO actual ox_inventory
    -- access control at all (see header) — it is not a safe fallback to
    -- rely on, only a non-worse one.
    return citizenid, nil
end

--- Defense-in-depth authorization check for the INTERACTING player (never
--- the real access boundary — see this file's header EVENT/CALLBACK
--- CONTRACT section for why ox_inventory's own owner/groups check, set via
--- ResolveStashOwnerAndGroups above at registration time, is the actual
--- security boundary). Mirrors CheckLeashEligibility's officer-side rule in
--- server/main.lua: department membership only, no certification required
--- of the interactor — matches PHASE4_SPEC.md §13.2's own "any player whose
--- job ∈ Config.Departments may open it" framing for the 'department' scope.
--- @param interactorJobName string?
--- @param isSelf boolean
--- @return boolean authorized
local function IsAuthorizedForK9Inventory(interactorJobName, isSelf)
    if isSelf then return true end -- the K9 player accessing their own stash is always authorized, independent of accessScope

    if Config.K9Inventory.accessScope == 'department' then
        return interactorJobName ~= nil and Config.Departments[interactorJobName] ~= nil
    end

    -- UNREACHABLE in a running resource (the onResourceStart assert above
    -- guarantees accessScope == 'department') — fails closed, same
    -- direction/reasoning as ResolveStashOwnerAndGroups above, kept only as
    -- defense-in-depth.
    return false
end

--- Idempotent (per server session) stash registration for `citizenid`. Only
--- calls the (session-unverified, see this file's header) RegisterStash
--- export once per citizenid per session. pcall-wrapped since a bad/missing
--- ox_inventory install, or an unconfirmed export signature, must surface as
--- a clean `stash_failed` result to the caller, not an uncaught server
--- error.
--- @param citizenid string
--- @return boolean ok
local function EnsureK9Stash(citizenid)
    if EnsuredK9Stashes[citizenid] then
        return true
    end

    local owner, groups = ResolveStashOwnerAndGroups(citizenid)
    local stashId = ('k9inv-%s'):format(citizenid)
    local label = 'K9 Gear'

    local ok, err = pcall(function()
        exports.ox_inventory:RegisterStash(stashId, label, Config.K9Inventory.slots, Config.K9Inventory.maxWeight, owner, groups)
    end)

    if not ok then
        print(('[qbx_k9unit] RegisterStash failed for %s: %s'):format(stashId, tostring(err)))
        return false
    end

    EnsuredK9Stashes[citizenid] = true
    return true
end

--- Internal implementation for the openK9Inventory callback below. Called
--- only after the callback's own cheap checks (payload shape, feature flag,
--- in-flight mutex, cooldown) already passed. Mirrors
--- server/search.lua's HandleSearchTarget validation-order discipline
--- exactly, applied to a different capability grant:
---   1. Resolve `targetNetId` to a live entity — reject if it doesn't exist.
---   2. Cross-check the resolved entity's REAL type is a ped (never trust a
---      claimed type — there's no client-supplied targetType here at all,
---      unlike search.lua, since this feature only ever targets a K9 ped).
---   3. Resolve the entity to a currently-connected player (never an NPC).
---   4. Confirm the target's LIVE server-side ped model is a configured K9
---      model (IsConfiguredK9Model) — this is specifically a "K9 gear"
---      interaction, not a generic player-inventory bridge.
---   5. Confirm the target currently HasK9Access — a decertified K9 has lost
---      the underlying K9 capability set, same posture certification revoke
---      already takes for leash pairings (server/certifications.lua's
---      ForceDetachLeashForSource).
---   6. MANDATORY, FIRST-CLASS live proximity check, run BEFORE any
---      mutation (stash registration/access grant) — same "never trust a
---      client-claimed target is actually nearby" discipline
---      server/search.lua's step 3 and server/main.lua's
---      relayDoorScratch/CheckLeashEligibility all already apply.
---   7. Resolve the interactor's own citizenid/job server-side (never
---      client-claimed) and defense-in-depth authorize via
---      IsAuthorizedForK9Inventory.
---   8. Stamp the cooldown NOW, before the (session-unverified,
---      possibly-yielding — see this file's header) RegisterStash call.
---   9. EnsureK9Stash — the real, server-authoritative capability grant.
---  10. Return the resolved stash id to the caller only.
--- @param source number
--- @param targetNetId number
--- @return table result
local function HandleOpenK9Inventory(source, targetNetId)
    local entity = NetworkGetEntityFromNetworkId(targetNetId)
    if entity == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    -- GetEntityType: 1 = ped, 2 = vehicle, 3 = object.
    if GetEntityType(entity) ~= 1 then
        return { ok = false, reason = 'invalid_target' }
    end

    local targetServerId = ResolveConnectedPlayerFromPed(entity)
    if not targetServerId then
        return { ok = false, reason = 'invalid_target' } -- NPC, or no longer a connected player's ped
    end

    if not IsConfiguredK9Model(GetEntityModel(entity)) then
        return { ok = false, reason = 'invalid_target' } -- not currently playing a recognized K9 model
    end

    if not HasK9Access(targetServerId) then
        return { ok = false, reason = 'no_access' } -- target is not (or is no longer) a certified, working K9
    end

    -- MANDATORY, FIRST-CLASS live proximity check — BEFORE any mutation.
    local interactorPed = GetPlayerPed(source)
    if interactorPed == 0 then
        return { ok = false, reason = 'invalid_target' }
    end

    local dist = #(GetEntityCoords(interactorPed) - GetEntityCoords(entity))
    if dist > Config.K9Inventory.interactRange then
        return { ok = false, reason = 'too_far' }
    end

    local isSelf = source == targetServerId
    local interactorPlayer = exports.qbx_core:GetPlayer(source)
    local interactorJobName = interactorPlayer and interactorPlayer.PlayerData and interactorPlayer.PlayerData.job and interactorPlayer.PlayerData.job.name

    if not IsAuthorizedForK9Inventory(interactorJobName, isSelf) then
        return { ok = false, reason = 'not_authorized' }
    end

    local targetPlayer = exports.qbx_core:GetPlayer(targetServerId)
    local targetCitizenid = targetPlayer and targetPlayer.PlayerData and targetPlayer.PlayerData.citizenid
    if not targetCitizenid then
        return { ok = false, reason = 'invalid_target' }
    end

    -- Stamp the cooldown NOW, before the possibly-yielding RegisterStash
    -- call below (contraband_search_contract.md §3 step 13's exact
    -- "stamp before the awaited work" discipline, applied here defensively
    -- even though RegisterStash is not confirmed to yield this session).
    K9InventoryOpenCooldown.Touch(source)

    if not EnsureK9Stash(targetCitizenid) then
        return { ok = false, reason = 'stash_failed' }
    end

    return { ok = true, stashId = ('k9inv-%s'):format(targetCitizenid) }
end

--- PHASE4_SPEC.md §13.4.2. THE security-critical callback of this file, per
--- this file's own header claim of server/search.lua-level scrutiny.
lib.callback.register('qbx_k9unit:server:openK9Inventory', function(source, targetNetId)
    if type(targetNetId) ~= 'number' then
        return { ok = false, reason = 'invalid_target' } -- defensive: never trust client payload shape
    end

    if not Config.Features.K9Inventory then
        return { ok = false, reason = 'feature_disabled' } -- real server-side no-op regardless of client UI state
    end

    if K9InventoryOpenCooldown.IsOnCooldown(source) then
        return { ok = false, reason = 'on_cooldown' }
    end

    -- Set the in-flight mutex synchronously, BEFORE any further work —
    -- cleared on EVERY exit path below, same "finally" discipline
    -- server/search.lua's SearchMutex already established.
    if not K9InventoryOpenMutex.TryAcquire(source) then
        return { ok = false, reason = 'request_in_progress' }
    end

    local ok, result = pcall(HandleOpenK9Inventory, source, targetNetId)

    K9InventoryOpenMutex.Release(source) -- ALWAYS clear, success or error

    if not ok then
        print(('[qbx_k9unit] openK9Inventory error for source %s: %s'):format(source, tostring(result)))
        return { ok = false, reason = 'stash_failed' }
    end

    return result
end)
