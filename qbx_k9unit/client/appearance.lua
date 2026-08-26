--[[
    qbx_k9unit/client/appearance.lua

    coder-architect. Client half of the K9 role/ped-model decoupling — see
    server/appearance.lua's header for the full design (role vs. model,
    what triggers a swap, the streaming-failure contract). This file owns
    exactly two things:
      1. IsK9Role() — the cached, network-backed "do I hold the K9 role"
         check, the same shape as client/main.lua's own HasK9Access() (same
         TTL, same fail-closed-on-throw posture), consulted by
         CanShowK9UI() (client/main.lua) when
         Config.K9Appearance.requireK9ModelForRole is false.
      2. The actual model swap: the 'qbx_k9unit:client:applyK9Ped' handler,
         which is the ONLY place in this resource that ever calls
         SetPlayerModel.

    ======================================================================
    PER-PED STATE ACROSS A MODEL SWAP — THE DECISION (item D of this pass):
    REFUSE, don't force-clear. FiveM's SetPlayerModel keeps the SAME ped
    index across the swap (already confirmed and relied on elsewhere in
    this resource — see client/movement.lua's RecomputeK9MoveRate doc
    comment), which is exactly the "death reuses the same ped handle"
    hazard this resource has already been bitten by once (a K9 that died
    in a vehicle respawned frozen/invisible/attached — a past regression
    caught and fixed; the underlying diary this was recorded in has since
    been consolidated away, see DEVELOPER_REFERENCE.md §16). A model swap
    is the SAME class of hazard: any
    resource-tracked per-ped state that assumes "this ped is a K9"
    (leashed, mid drag as either party, mid bite-hold, mid fetch-carry,
    inside a K9 vehicle) would silently carry over onto whatever the ped
    becomes next.

    This file does NOT own client/combat.lua, client/movement.lua,
    client/fetch.lua or client/vehicle.lua, so it cannot reach into their
    private state to force-clear it correctly (and guessing at a
    force-clear sequence for state this file doesn't own is exactly how
    the vehicle/frozen bug above happened in the first place). Every one of
    those files already exposes a cheap, resource-global "am I currently
    doing this" check for exactly this kind of cross-file consultation —
    reused here, read-only, never called to mutate anything:
        IsLeashed()               client/movement.lua
        IsBiteHoldEngaged()       client/combat.lua
        IsDragEngaged()           client/combat.lua
        IsFetchCarryEngaged()     client/fetch.lua
        IsInK9Vehicle()           client/vehicle.lua
        IsPropAttachmentEngaged() client/propattachment.lua
    If ANY of these is true, the swap is refused outright (before
    RequestModel is even called) and reported back to the server as
    'engaged' — never half-applied, never a guess at cleanup this file has
    no authority over. Each is guarded with the established
    `type(fn) == 'function'` soft-dependency check, since this file has no
    hard load-order requirement on any of theirs.

    CLOSED GAP (this pass): client/propattachment.lua now exposes
    IsPropAttachmentEngaged() (same shape/convention as the five predicates
    above), added specifically to close a previously-disclosed gap in this
    same check — a K9 mid-PropAttachment is covered below exactly like every
    other engagement kind.

    ======================================================================
    STREAMING — RequestModel/HasModelLoaded polling, timed out by
    Config.K9Appearance.modelLoadTimeoutMs, is the SAME pattern
    client/kennel.lua's LoadModelWithTimeout already established (down to
    the leak fix: SetModelAsNoLongerNeeded on EVERY exit path, including
    the timeout one, since RequestModel's streaming reference must always
    be released even when the model that was requested is never actually
    used). On timeout: SetModelAsNoLongerNeeded, report 'timeout' back to
    the server, and do nothing else — SetPlayerModel is never called, so
    the player is exactly as they were before this request arrived.

    ======================================================================
    STATEBAG VS CACHED CALLBACK — THE DECISION ("I also want everything to
    work with any ped" pass): ten ox_target canInteract predicates across
    client/movement.lua, client/medkit.lua, client/wellbeing.lua and
    client/partnership.lua need "does THAT OTHER player currently hold the
    K9 role", not just IsK9Role()'s own "do I". An architecture pass floated
    a replicated statebag (Player(source).state:set('isK9', bool, true) set
    server-side at every role-transition point — grant, revoke, ped-swap
    apply/revert/timeout, disconnect — read client-side via
    Entity(ped).state.isK9) as the no-round-trip alternative.

    DECISION: cached callback (IsK9RoleForPlayer below), NOT a statebag.
    This resource has zero statebags today; introducing the pattern for
    exactly one predicate-convenience question is not worth the blast
    radius it would open — every one of the four bullet points above
    becomes a NEW place a role-transition can be missed (an unset on
    disconnect that never fires leaves a stale `true` broadcast to every
    client forever, until that slot is reused and overwritten — worse than
    a cached callback's own worst case, which self-heals within one TTL
    window with no additional code path required). A statebag write is also
    only reachable from server/appearance.lua (the one file that already
    owns every role-transition point HasK9Role's own cache backs onto), so
    the "four separate call sites, each must remember" risk is real, not
    theoretical — server/appearance.lua's own header above already
    documents ForceDetachLeashForSource-class cross-file coordination gaps
    as the recurring hazard class in this resource.

    The cached callback pays for this with an up-to-1000ms staleness window
    and a real (rate-bounded) round trip per newly-hovered target — both
    already true of every OTHER predicate in this resource that answers "is
    THAT OTHER player currently X" (see client/main.lua's own HasK9Access()
    TTL reasoning, identical shape), and per this file's own "A PREDICATE IS
    A CONVENIENCE GATE" rule below: canInteract only decides whether an
    ox_target OPTION is offered, never whether the resulting action
    succeeds — every one of those ten predicates' own onSelect handlers
    still triggers a server event/callback that independently re-derives
    "does this target hold the K9 role" via HasK9Role/HasK9Access, exactly
    as if the predicate had answered `true` for the wrong reason or a
    forged/stale value. A staleness window here can make a menu OPTION
    appear or vanish a beat late; it can never make the action itself
    succeed against a target who does not actually hold the role. If a
    future pass finds this round-trip volume actually costly in practice
    (not hypothetically), the statebag above remains the documented
    alternative — this decision is about NOT paying that cost today for a
    convenience-only surface, not a claim the pattern is wrong for this
    resource forever.

    ======================================================================
    EVENT CONTRACT — see server/appearance.lua's header for the full
    picture; this file registers the client end and triggers the confirm:
      'qbx_k9unit:client:applyK9Ped' (requestId: string, modelNameOrHash: string|number) [THIS FILE, server->client]
      'qbx_k9unit:server:confirmK9PedSwap' (requestId: string, ok: boolean, reason: string?) [THIS FILE, client->server]
      'qbx_k9unit:server:hasK9Role' (lib.callback) () -> boolean [server/appearance.lua]
      'qbx_k9unit:server:isK9RoleForTarget' (lib.callback) (targetServerId: number) -> boolean [server/appearance.lua] -- backs IsK9RoleForPlayer below
]]

-- Same cache shape/TTL as client/main.lua's HasK9Access() — see that
-- function's own doc comment for the full "why 1000ms, why a debounce not
-- a permanent cache" reasoning, which applies identically here (this is
-- consulted from the exact same CanShowK9UI() combinator, so it needs the
-- same hot-call-site headroom).
local HAS_K9_ROLE_CACHE_TTL_MS = 1000
local hasK9RoleCache = { value = false, checkedAt = -HAS_K9_ROLE_CACHE_TTL_MS }

--- Awaits the server's authoritative "do I hold the K9 role" check (see
--- server/appearance.lua's HasK9Role — active certification for my current
--- job, OR an active 'k9.access' permission grant; model-independent by
--- construction). Same FAIL-CLOSED-ON-THROW guard as HasK9Access(): a
--- rejected `lib.callback.await` (timeout / not-yet-registered) throws
--- rather than returning nil (client/main.lua's HasK9Access doc comment
--- has the full citation against real ox_lib/FiveM source, not repeated
--- here), so this is pcall'd and denies for just this one call on a
--- throw, WITHOUT poisoning the cache with a false negative — identical
--- reasoning to HasK9Access's own comment on why `checkedAt` is left
--- untouched on that path.
--- @return boolean
function IsK9Role()
    local now = GetGameTimer()
    if (now - hasK9RoleCache.checkedAt) < HAS_K9_ROLE_CACHE_TTL_MS then
        return hasK9RoleCache.value
    end

    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:hasK9Role', false)
    if not ok then
        return false
    end

    hasK9RoleCache.value = result == true
    hasK9RoleCache.checkedAt = now
    return hasK9RoleCache.value
end

-- Per-target cache, same TTL/shape as hasK9RoleCache above but keyed by
-- targetServerId -- a peer audit (this pass) found ten ox_target
-- canInteract predicates across files this pass does not own that need
-- "is THAT OTHER player a K9-role holder", not just the local player (see
-- server/appearance.lua's isK9RoleForTarget callback doc comment for the
-- full list/reasoning). One cache per target rather than one shared value,
-- since a canInteract predicate can be evaluated against several different
-- nearby players in quick succession while the mouse moves.
local HAS_K9_ROLE_FOR_TARGET_CACHE_TTL_MS = 1000
local k9RoleForTargetCache = {} -- [targetServerId] = { value, checkedAt }

--- Awaits the server's authoritative "does THAT player hold the K9 role"
--- check. CONVENIENCE ONLY, same posture as every other ox_target
--- canInteract predicate in this resource -- callers must not treat a
--- `true` here as authorization for anything; the real action still goes
--- through a server-side HasK9Role/HasK9Access re-check regardless. Same
--- fail-closed-on-throw-without-poisoning-the-cache guard as IsK9Role()/
--- HasK9Access() above.
--- @param targetServerId number
--- @return boolean
function IsK9RoleForPlayer(targetServerId)
    if type(targetServerId) ~= 'number' then return false end

    local now = GetGameTimer()
    local cached = k9RoleForTargetCache[targetServerId]
    if cached and (now - cached.checkedAt) < HAS_K9_ROLE_FOR_TARGET_CACHE_TTL_MS then
        return cached.value
    end

    local ok, result = pcall(lib.callback.await, 'qbx_k9unit:server:isK9RoleForTarget', false, targetServerId)
    if not ok then
        return false
    end

    k9RoleForTargetCache[targetServerId] = { value = result == true, checkedAt = now }
    return result == true
end

--- @return boolean
local function IsCurrentlyEngaged()
    if type(IsLeashed) == 'function' and IsLeashed() then return true end
    if type(IsBiteHoldEngaged) == 'function' and IsBiteHoldEngaged() then return true end
    if type(IsDragEngaged) == 'function' and IsDragEngaged() then return true end
    if type(IsFetchCarryEngaged) == 'function' and IsFetchCarryEngaged() then return true end
    if type(IsInK9Vehicle) == 'function' and IsInK9Vehicle() then return true end
    if type(IsPropAttachmentEngaged) == 'function' and IsPropAttachmentEngaged() then return true end
    return false
end

--- @return number
local function ModelLoadTimeoutMs()
    local timeout = Config.K9Appearance and Config.K9Appearance.modelLoadTimeoutMs
    if type(timeout) ~= 'number' or timeout <= 0 then return 10000 end
    return timeout
end

--- Same RequestModel/HasModelLoaded polling pattern, INCLUDING the leak
--- fix, as client/kennel.lua's LoadModelWithTimeout — see that function's
--- own doc comment for the full "why this exact shape" writeup, not
--- repeated here. The one difference: this takes an already-resolved HASH
--- (a caller-supplied model name is hashed by the caller below, and a
--- revert's original-model hash never had a name to begin with — see
--- server/appearance.lua's own comment on why original_model_hash is
--- stored as a hash, not a name).
--- @param modelHash number
--- @return boolean ok
local function LoadModelWithTimeout(modelHash)
    if not IsModelValid(modelHash) then
        return false -- not even a recognized model hash on this client's installed game data
    end

    RequestModel(modelHash)
    local waited = 0
    local timeoutMs = ModelLoadTimeoutMs()
    while not HasModelLoaded(modelHash) and waited < timeoutMs do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        -- LEAK FIX, same as client/kennel.lua's identical comment: RequestModel
        -- above incremented this model's streaming reference count; release it
        -- on this failure path too, or it is held forever.
        SetModelAsNoLongerNeeded(modelHash)
        return false
    end
    return true
end

--- @param requestId string
--- @param ok boolean
--- @param reason string?
local function ConfirmSwap(requestId, ok, reason)
    TriggerServerEvent('qbx_k9unit:server:confirmK9PedSwap', requestId, ok, reason)
end

--- @param modelNameOrHash string|number
--- @return number
local function ResolveModelHash(modelNameOrHash)
    if type(modelNameOrHash) == 'string' then
        return GetHashKey(modelNameOrHash)
    end
    return modelNameOrHash
end

--- The ONLY call site for SetPlayerModel in this resource. See this file's
--- header for the full "refuse, don't force-clear" and streaming-timeout
--- contracts.
--- @param requestId string
--- @param modelNameOrHash string|number
RegisterNetEvent('qbx_k9unit:client:applyK9Ped', function(requestId, modelNameOrHash)
    -- SOURCE-ORIGIN GUARD, same pattern/confidence as every other
    -- server->client event in this resource (see client/main.lua's
    -- playBark handler for the fullest citation of this pattern).
    if source ~= 65535 then return end

    if type(requestId) ~= 'string' or requestId == '' then return end
    if type(modelNameOrHash) ~= 'string' and type(modelNameOrHash) ~= 'number' then return end

    if IsCurrentlyEngaged() then
        ConfirmSwap(requestId, false, 'engaged')
        return
    end

    local modelHash = ResolveModelHash(modelNameOrHash)
    if not LoadModelWithTimeout(modelHash) then
        ConfirmSwap(requestId, false, 'timeout')
        return
    end

    SetPlayerModel(PlayerId(), modelHash)
    SetModelAsNoLongerNeeded(modelHash)

    -- Local role-check cache may now be answering for the model we just
    -- left — force the next CanShowK9UI()/IsK9Role() consultation to
    -- re-await rather than serve a value cached from before this swap.
    -- (IsOwnModelK9() itself has no cache to invalidate — it always reads
    -- the ped's current model live.)
    hasK9RoleCache.checkedAt = -HAS_K9_ROLE_CACHE_TTL_MS

    ConfirmSwap(requestId, true, nil)
end)
