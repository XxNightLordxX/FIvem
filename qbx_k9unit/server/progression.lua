--[[
    qbx_k9unit/server/progression.lua

    Phase 4 (coder-backend). Owns `Config.Features.XPProgression` end to
    end: server-authoritative XP accumulation, the `k9_progression`
    persistence table (sql/install.sql), the `K9XP[citizenid]` in-memory
    cache mirroring `server/certifications.lua`'s `Certifications` cache
    pattern exactly (per phase2_notes/phase4_xp_schema_notes.md §5's own
    recommendation), and the tier-lookup helper walking `Config.XPTiers` the
    same way `server/search.lua` walks `Config.ContrabandAlertTiers`.

    PERSISTENCE DECISION (not re-litigated here — see
    phase2_notes/phase4_xp_schema_notes.md, db-schema's design note, and
    PHASE4_SPEC.md §13.4.1/§13.5's own header claiming this note is
    "adopted"): a dedicated table, `k9_progression`, ONE ROW PER CITIZENID —
    NOT a qbx_core metadata field. XP is real, mechanical, capability-
    adjacent state (a tier crossing changes a K9's actual scent range and
    movement speed, per Config.XPTiers), the same category of decision this
    resource already made once for `k9_certifications` over metadata
    (SPEC.md §4.3), for the same three reasons: offline correction must
    work, atomic accumulation needs a single UPSERT (not a Lua-side
    read-modify-write race), and admin/ops queryability without scanning
    every player's JSON blob. See sql/install.sql's own `k9_progression`
    header comment for the schema itself.

    SCOPING: per Config.XP.scopePerCitizenidOrJob (currently only
    'citizenid' is implemented — see that config field's own comment and
    PHASE4_SPEC.md §13.6 item 2 for the still-open 'job' alternative, a
    product call this file does not attempt to resolve). `k9_progression`
    has a plain `citizenid` PRIMARY KEY, no job column — XP survives a
    department change, unlike `k9_certifications`.

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 4. Identical in format to
    server/certifications.lua's contract block.

    Callbacks: none. There is no "what's my current XP/tier" callback —
    every tier-relevant push is the server-initiated event below; a future
    UI wanting to *display* XP can read from that push, not poll for it.

    Server events (RegisterNetEvent, client->server): NONE for awarding XP.
    Every award is server-triggered internally, from inside the existing
    server-side success paths of server/search.lua and server/tracking.lua
    (this pass), and eventually server/combat.lua once Phase 3 lands (see
    Config.XP.awards' own comments in config.lua) — never from a
    client-fired "I earned XP" event. There is no legitimate reason for a
    client to ever claim this, and none is exposed.

    Client events (RegisterNetEvent, server->client):
    1. 'qbx_k9unit:client:xpTierChanged' (newTier: table — a full entry
       from Config.XPTiers: { xp, label, speedMultiplier, scentRange })
       [client/progression.lua] — sent to the K9's own client ONLY
       (never broadcast), on: (a) PlayerLoaded / resource-start backfill
       (an authoritative snapshot so a returning K9 doesn't need to earn
       fresh XP this session before their tier's effects apply again), and
       (b) any real tier crossing caused by AwardXP below. client/progression.lua
       does not need to distinguish (a) from (b) for correctness (it always
       applies newTier.speedMultiplier to K9MoveRateModifiers.xpTier either
       way) — it only distinguishes them for whether to show a "you leveled
       up" notification (never on the initial post-login snapshot).

    Commands: none.

    Automatic path: 'QBCore:Server:PlayerLoaded' (cache warm + initial
    snapshot push) and the resource-start backfill loop below (mirrors
    server/main.lua's own onResourceStart backfill for Certifications,
    same structural-gap rationale: a `/restart qbx_k9unit` while players are
    already online needs to re-warm K9XP for them too, since PlayerLoaded
    never re-fires for an already-connected player).
    ======================================================================

    FILE-TO-FILE CONTRACT — THIS FILE exposes three resource-global (no
    `local`) functions:
        AwardXP(citizenid, actionKey)
            actionKey is a string key into Config.XP.awards (e.g.
            'searchContrabandFound', 'trackSourceResolved',
            'biteHoldSuccess', 'takedownSuccess'). Re-checks
            Config.Features.XPProgression itself (defensive no-op if
            disabled, per SPEC.md §3 — callers are not required to gate
            this themselves, though every current call site already does
            for clarity). Updates the in-memory K9XP cache SYNCHRONOUSLY
            before firing a non-blocking DB UPSERT (phase4_xp_schema_notes.md
            §5 — correctness of the applied gameplay effect never depends on
            DB round-trip latency). Called from server/search.lua and
            server/tracking.lua this pass via a `type(AwardXP) == 'function'`
            runtime existence guard (the same guard server/medkit.lua's
            RestoreInjury call site already established for an equivalent
            soft cross-file dependency) — NOT a load-order assumption, so
            this file's position in fxmanifest.lua's server_scripts list is
            not load-bearing for those callers. server/combat.lua, once
            built, should call this the same way for 'biteHoldSuccess'/
            'takedownSuccess' — see config.lua's own comment on those two
            award keys.
        GetXPTier(citizenid) -> table
            Always returns a real Config.XPTiers entry (never nil) — an
            unknown/not-yet-cached citizenid resolves to the base tier
            (Config.XPTiers[1], 0 XP), the same "unknown state defaults to
            least privilege" posture this resource already applies
            elsewhere. Read by server/tracking.lua's findTrackableSource to
            apply the tier's `scentRange` server-side — callers are
            responsible for gating this read behind
            Config.Features.XPProgression themselves (this accessor does
            not gate internally, so it stays a plain, always-correct cache
            read regardless of caller).
        GetXP(citizenid) -> number
            Raw accumulated total (0 if uncached). Not currently consumed
            anywhere in this resource — exposed for a future HUD/display
            need (PHASE4_SPEC.md §13.4.1's own "additive read, not a new
            authorization surface" framing) rather than re-deriving a
            second cache elsewhere.
    THIS FILE calls `HasK9Access`... it does NOT — AwardXP is only ever
    invoked from a caller that has already independently re-verified
    HasK9Access for the acting player at its own call site (server/search.lua,
    server/tracking.lua); duplicating that check here would be redundant,
    not defense-in-depth, since AwardXP is not itself a network-facing
    surface (no RegisterNetEvent/lib.callback reaches it directly).
    THIS FILE owns `K9XP` (citizenid -> number) as file-local state,
    structurally identical to server/certifications.lua's `Certifications`
    cache (refreshed on PlayerLoaded/resource-start backfill, evicted on
    playerDropped to bound memory growth, per that file's own "regression-
    test fix" precedent).
    ======================================================================
]]

-- K9XP[citizenid] = number (accumulated total). Local: nothing outside this
-- file should read/write it directly — always go through AwardXP/GetXPTier/
-- GetXP. Mirrors server/certifications.lua's `Certifications` cache shape
-- and its own "nothing outside this file should read it directly" rule.
local K9XP = {}

-- CONFIG-SAFETY GUARD (config audit finding, this pass — same precedent as
-- server/inventory.lua's `Config.K9Inventory.accessScope` assert and
-- server/main.lua's `nudgeRequiresUnlocked` assert). This file's own header
-- SCOPING section, config.lua's own comment on this field, and README.md's
-- `Config.Features.XPProgression` section all already document that only
-- `'citizenid'` is implemented — but until now nothing ever READ the value
-- to enforce that, so a server owner who set `'job'` (a documented, but
-- explicitly NOT-YET-built, alternative — PHASE4_SPEC.md §13.6 item 2) got
-- silently citizenid-scoped behaviour with no warning at all: every award
-- and lookup in this file goes straight through K9XP[citizenid] and the
-- `k9_progression` table's plain `citizenid` key, never once branching on
-- this config field.
--
-- This is NOT a "feature merely unimplemented, pick the other value and
-- wait" situation the way an inert placeholder would be — `k9_progression`
-- (sql/install.sql) has a plain `VARCHAR(50) citizenid` PRIMARY KEY and NO
-- job column at all. 'job' scoping would need a composite (citizenid, job)
-- key instead (mirroring `k9_certifications`), which is a SCHEMA change,
-- not a config choice this file could honor today even if it tried to
-- switch on the value — the current schema cannot express per-job XP
-- totals at all. Failing loudly at resource start, rather than letting a
-- misconfigured value silently produce behaviour the operator did not
-- choose, matches the established precedent above.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    assert(
        Config.XP.scopePerCitizenidOrJob == 'citizenid',
        "[qbx_k9unit] Config.XP.scopePerCitizenidOrJob must be 'citizenid' -- " ..
        "'job' is a documented-but-unimplemented alternative (PHASE4_SPEC.md §13.6 item 2), " ..
        'not a selectable config choice this file can honor: the `k9_progression` table ' ..
        '(sql/install.sql) has a plain `citizenid` PRIMARY KEY and no job column at all, so ' ..
        "job-scoped XP totals cannot even be persisted under the current schema, let alone " ..
        'read/written correctly by this file, which unconditionally keys every K9XP cache ' ..
        'entry and every k9_progression query by citizenid alone. Setting this to anything ' ..
        "other than 'citizenid' would silently keep citizenid-scoped behaviour with no " ..
        'warning, misleading an operator who believes they configured job-scoped progression.'
    )
end)

--- Resolves `xp` to the matching entry in Config.XPTiers. Identical walk
--- shape to server/search.lua's ResolveAlertTier — Config.XPTiers[1] is the
--- mandatory `xp = 0` baseline (same role Config.ContrabandAlertTiers'
--- `minWeight = 0` baseline plays there), so this never returns nil.
--- Returns the SAME table object (by reference) for every xp value that
--- falls in one tier's bracket, which AwardXP below relies on to detect a
--- tier crossing via plain `~=` comparison rather than a deep-equality
--- check.
--- @param xp number
--- @return table tier -- { xp, label, speedMultiplier, scentRange }
local function ResolveTier(xp)
    local resolvedTier = Config.XPTiers[1]
    for _, tier in ipairs(Config.XPTiers) do
        if xp >= tier.xp then
            resolvedTier = tier
        end
    end
    return resolvedTier
end

--- Resource-global — see FILE-TO-FILE CONTRACT above. Always returns a real
--- Config.XPTiers entry, defaulting to the base tier for an uncached
--- citizenid (never nil, never a security-relevant fail-open — the base
--- tier grants the SMALLEST scentRange/speedMultiplier in the table, so an
--- unresolved cache entry can only ever under-grant, never over-grant).
--- @param citizenid string
--- @return table tier
function GetXPTier(citizenid)
    return ResolveTier(K9XP[citizenid] or 0)
end

--- Resource-global — see FILE-TO-FILE CONTRACT above.
--- @param citizenid string
--- @return number
function GetXP(citizenid)
    return K9XP[citizenid] or 0
end

--- Loads a citizenid's real XP total from k9_progression into the K9XP
--- cache. pcall-wrapped mirroring server/certifications.lua's
--- RefreshCertificationCache precedent — an uncaught error here must not
--- abort the caller's own loop (PlayerLoaded fires per-player, but the
--- resource-start backfill loop below iterates every connected player in
--- one handler invocation, and FXServer's dispatch pcalls the whole
--- handler, not each iteration, so one bad row would otherwise wedge every
--- subsequent player — the exact bug class server/main.lua's own backfill
--- loop header already documents finding and fixing once for
--- certifications). Unlike certification access, a failed XP read has no
--- security consequence either way (XP grants a bounded scent/speed bonus,
--- never a permission), so this fails to a safe 0-XP baseline rather than
--- "failing closed" in the access-control sense.
--- @param citizenid string
--- @return number xp -- the freshly-cached value
local function LoadXPForCitizenid(citizenid)
    local queryOk, xpOrErr = pcall(MySQL.scalar.await, 'SELECT xp FROM k9_progression WHERE citizenid = ? LIMIT 1', {
        citizenid,
    })

    if not queryOk then
        print(('[qbx_k9unit] progression: LoadXPForCitizenid query failed for %s: %s'):format(citizenid, tostring(xpOrErr)))
        K9XP[citizenid] = 0
        return 0
    end

    K9XP[citizenid] = xpOrErr or 0 -- no row yet = 0 XP / base tier, same as k9_certifications' "no active cert row" = false
    return K9XP[citizenid]
end

--- Pushes an authoritative tier snapshot to a specific, currently-connected
--- player's client. Gated on Config.Features.XPProgression — no client-side
--- consequence should ever apply while the feature is disabled, per
--- SPEC.md §3's "read the flag at the point of use" rule; the K9XP cache
--- itself is still warmed/kept in sync regardless of the flag (cheap, and
--- avoids losing real accumulated progress data just because the feature
--- is temporarily toggled off).
--- @param targetSrc number
--- @param tier table
local function PushTierSnapshot(targetSrc, tier)
    if not Config.Features.XPProgression then return end
    TriggerClientEvent('qbx_k9unit:client:xpTierChanged', targetSrc, tier)
end

--- Resource-global — see FILE-TO-FILE CONTRACT above for the full contract.
--- THE single server-authoritative XP-award entry point. Never trusts a
--- client-claimed XP delta or tier — `actionKey` selects a flat, config-owned
--- amount; there is no path for a caller (or, transitively, a client) to
--- specify an arbitrary amount.
--- @param citizenid string
--- @param actionKey string -- a key in Config.XP.awards
function AwardXP(citizenid, actionKey)
    if not Config.Features.XPProgression then return end -- real server-side no-op regardless of caller state, per SPEC.md §3
    if type(citizenid) ~= 'string' or citizenid == '' then return end -- defensive: never trust a malformed caller argument

    local amount = Config.XP.awards[actionKey]
    if type(amount) ~= 'number' then
        -- Defensive: an unknown actionKey is a CALLER bug (a typo'd string
        -- literal at a new call site), not a runtime condition to silently
        -- swallow — log it so it's visible in server console rather than
        -- silently granting 0 XP forever.
        print(('[qbx_k9unit] progression: AwardXP called with unknown actionKey %q for citizenid %s'):format(tostring(actionKey), citizenid))
        return
    end

    local oldXp = K9XP[citizenid] or 0
    local oldTier = ResolveTier(oldXp)

    local newXp = oldXp + amount
    -- Update the in-memory cache SYNCHRONOUSLY, before the DB write below —
    -- phase2_notes/phase4_xp_schema_notes.md §5: correctness of the applied
    -- gameplay effect (tier-derived scentRange/speedMultiplier) depends only
    -- on this line, never on DB round-trip latency.
    K9XP[citizenid] = newXp

    -- Non-blocking, atomic UPSERT — same fire-and-forget posture as
    -- server/search.lua's LogSearchAttempt (a slow/contended DB write must
    -- never delay or risk whatever server-side success path just called
    -- this function), pcall-wrapped for the same reason: a logging/
    -- persistence failure here must never surface as (or cause) a failure
    -- in the caller's own action. `amount` (the delta), not `newXp` (the
    -- new total), is the second bound parameter — `VALUES(xp)` on the
    -- ON DUPLICATE KEY branch refers to the just-inserted delta, giving a
    -- single-statement atomic increment-or-create with no separate
    -- SELECT-then-UPDATE round trip (phase2_notes/phase4_xp_schema_notes.md §4).
    pcall(MySQL.insert, [[
        INSERT INTO k9_progression (citizenid, xp) VALUES (?, ?)
          ON DUPLICATE KEY UPDATE xp = xp + VALUES(xp), updated_at = CURRENT_TIMESTAMP
    ]], { citizenid, amount })

    local newTier = ResolveTier(newXp)
    if newTier ~= oldTier then
        -- Only push if the citizenid resolves to a CURRENTLY connected
        -- player — every real call site today only ever awards XP to the
        -- player who just performed the action (always online at call
        -- time), but this stays generic (GetPlayerByCitizenId, not an
        -- assumed `source`) rather than asserting that invariant, mirroring
        -- server/certifications.lua's ForceDetachLeashIfOnline's own
        -- "resolve by citizenid, no-op if not currently online" shape.
        local onlinePlayer = exports.qbx_core:GetPlayerByCitizenId(citizenid)
        local onlineSrc = onlinePlayer and onlinePlayer.PlayerData and onlinePlayer.PlayerData.source
        if type(onlineSrc) == 'number' then
            PushTierSnapshot(onlineSrc, newTier)
        end
    end
end

AddEventHandler('QBCore:Server:PlayerLoaded', function(Player)
    if not Player or not Player.PlayerData then return end
    local citizenid = Player.PlayerData.citizenid
    if type(citizenid) ~= 'string' or citizenid == '' then return end

    local xp = LoadXPForCitizenid(citizenid)

    -- Authoritative snapshot on every login, unconditionally (not just on a
    -- "change" from some prior value) — a freshly connected client has no
    -- prior client-side tier state to diff against at all, so there is
    -- nothing to compare here. See client/progression.lua's own
    -- xpTierChanged handler for how it avoids treating this as a fresh
    -- level-up notification.
    local targetSrc = Player.PlayerData.source
    if type(targetSrc) == 'number' then
        PushTierSnapshot(targetSrc, ResolveTier(xp))
    end
end)

-- STRUCTURAL GAP backfill (mirrors server/main.lua's identical backfill for
-- Certifications, same rationale restated here for THIS cache): a
-- `/restart qbx_k9unit` while players are already online does not re-fire
-- PlayerLoaded for them, so their K9XP entry would sit at the default
-- ResolveTier(0) baseline (silently losing their real tier's scent/speed
-- bonus for the remainder of their session) until their next reconnect —
-- unless this loop re-warms the cache immediately at resource start.
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    for _, playerIdStr in ipairs(GetPlayers()) do
        local src = tonumber(playerIdStr)
        if src then
            local Player = exports.qbx_core:GetPlayer(src)
            if Player and Player.PlayerData and Player.PlayerData.citizenid then
                local citizenid = Player.PlayerData.citizenid
                local xp = LoadXPForCitizenid(citizenid)
                PushTierSnapshot(src, ResolveTier(xp))
            end
        end
    end
end)

-- Regression-test-class fix, applied proactively (mirrors
-- server/certifications.lua's own documented fix for the identical shape of
-- bug on its `Certifications` cache): K9XP is keyed by citizenid and would
-- otherwise accumulate one entry per distinct citizenid ever loaded this
-- session with nothing ever evicting an entry — not a correctness bug (a
-- stale cached total for a now-offline citizenid is simply never read again
-- until PlayerLoaded repopulates it fresh), just unbounded memory growth on
-- a long-running server. Resolve the citizenid for the disconnecting source
-- via qbx_core (still resolvable here — playerDropped fires before the
-- framework fully tears down the player object, same timing
-- server/certifications.lua's own playerDropped handler already relies on)
-- and drop its cache entry.
AddEventHandler('playerDropped', function(_reason)
    local src = source
    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if citizenid then
        K9XP[citizenid] = nil
    end
end)
