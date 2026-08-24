--[[
    qbx_k9unit/client/main.lua

    Phase 1 scaffold only (coder-architect). REWRITTEN after SPEC.md's
    post-draft correction. Owns the two building-block checks every other
    client file gates on — "is my own character a K9 model" (display-only,
    client-side) and "does the server say I have K9 access" (the real
    security boundary) — plus the combinator both radial.lua and
    vehicle.lua should call before showing/allowing anything. Also owns
    the bark-playback receiver, since it's about the K9 ped/entity in
    general rather than any one specific subsystem (movement/radial/vehicle).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 1 (full copy; see
    server/certifications.lua for the most detailed version of this same
    block):

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:hasK9Access' () -> boolean [server/certifications.lua]
       job.name ∈ Config.Departments AND active cert for that job (or
       autoAccessGrade bypass). Does NOT check ped model (§4.1/§4.5) —
       model is a grant-time-only check server-side, and a display-only
       self-check client-side (see IsOwnModelK9() below).

    Server events (RegisterNetEvent, client->server):
    2. 'qbx_k9unit:server:certifyHandler' (targetServerId: number) [server/certifications.lua]
    3. 'qbx_k9unit:server:revokeHandler' (targetServerId: number) [server/certifications.lua]
    4. 'qbx_k9unit:server:relayBark' (barkType: string) [server/main.lua]
       Triggered from client/radial.lua's Bark item — no netId argument,
       the server resolves the sender's own ped.

    Client events (RegisterNetEvent, server->client):
    5. 'qbx_k9unit:client:playBark' (netId: number, barkType: string) [THIS FILE]

    Commands: both live in server/certifications.lua.

    REMOVED from the original (pre-correction) scaffold — do not
    resurrect: ped-selection context menu, SpawnK9/DespawnK9,
    GetCurrentK9/SetCurrentK9/ClearCurrentK9 "current K9" state,
    'qbx_k9unit:server:requestSpawnK9' callback,
    'qbx_k9unit:server:registerK9'/'unregisterK9' events,
    'qbx_k9unit:client:despawnK9' event. There is no ped to select, spawn,
    register, or despawn — the K9 player plays their own persistent
    character at all times (SPEC.md §1, §2).
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes three resource-global (no `local`) functions,
      used by client/movement.lua, client/radial.lua, and client/vehicle.lua,
      PLUS ResolveNetworkEntity() (see its own doc comment near
      PlaySoundOnNetworkEntity below — REFACTOR_ROADMAP.md near-term item 2):
        IsOwnModelK9() -> boolean
            Pure local check (GetEntityModel(PlayerPedId()) against
            Config.Peds) — display-only, per §4.5, never treat this as a
            security boundary.
        HasK9Access() -> boolean
            Awaits the 'qbx_k9unit:server:hasK9Access' callback for the
            LOCAL player. This is a real network round-trip; per SPEC.md
            §4.1 ("checked... on every access point... not just once") it
            must be re-awaited at each point of use, not cached forever —
            but DO cache it briefly (a TODO below) so a hot call site like
            an ox_target `canInteract` predicate (which can run many times
            a second while hovering) doesn't flood the server.
        CanShowK9UI() -> boolean
            Combinator: IsOwnModelK9() and HasK9Access(). THIS is the
            function radial.lua/vehicle.lua/movement.lua should actually
            call for their gating decisions — don't call the other two
            directly from other files, so the "how do we combine these"
            policy lives in exactly one place.
      NOTE: server/certifications.lua also exposes a function named
      `HasK9Access(source)`, on the SERVER side. These are different Lua
      VMs (client vs. server) so there's no actual name collision — the
      shared name is intentional, for readability (same concept, mirrored
      API), not a shared symbol.

    OPEN QUESTION flagged for coder-frontend (not decided here): does the
    first/third-person eye-height camera toggle (SPEC.md §6.1 bullet 2)
    and native run/jump/crouch (bullet 3) need to be gated by CanShowK9UI()
    at all, or are they baseline behavior available to anyone playing a
    K9-model character regardless of job/cert (the game already gives any
    ped model its native locomotion for free; gating a QoL camera toggle
    behind certification arguably adds friction without protecting
    anything, since the player is visibly a dog either way)? This
    scaffold's lean: do NOT gate camera/locomotion behind CanShowK9UI(),
    only gate the radial menu (leash/vehicle/bark, which are the actual
    granted capabilities) — but this is a judgment call, not a spec
    mandate; flag disagreement rather than silently building it the other
    way.
]]

--- Precomputed set of Config.Peds model hashes, built once at file load.
--- Mirrors server/certifications.lua's K9ModelHashes approach so both
--- sides stay generic over the config (SPEC.md §3 acceptance bullet 3) —
--- no hardcoded model name anywhere, including custom streamed entries.
local K9ModelHashes = {}
for _, pedEntry in ipairs(Config.Peds) do
    K9ModelHashes[GetHashKey(pedEntry.model)] = true
end

--- Pure client-side, display-only check: is the local player's OWN
--- character currently a recognized K9 model? Never used for security —
--- see SPEC.md §4.5 ("Convenience (client)" bullet).
--- @return boolean
function IsOwnModelK9()
    return K9ModelHashes[GetEntityModel(PlayerPedId())] == true
end

-- Lightweight TTL cache for HasK9Access() below. Hot call sites (ox_target
-- canInteract predicates in client/vehicle.lua and client/movement.lua's
-- leash option in particular) can run several times a second while
-- hovering — without this, each of those would re-await the server
-- callback on every frame. ~1000ms keeps "checked... not just once"
-- (SPEC.md §4.1) true in spirit: this is a debounce, not a permanent
-- cache, and every gated server-side action independently re-verifies
-- access regardless of what this cache currently believes.
local HAS_K9_ACCESS_CACHE_TTL_MS = 1000
local hasK9AccessCache = { value = false, checkedAt = -HAS_K9_ACCESS_CACHE_TTL_MS }

--- Awaits the server's authoritative access check for the LOCAL player.
--- @return boolean
function HasK9Access()
    local now = GetGameTimer()
    if (now - hasK9AccessCache.checkedAt) < HAS_K9_ACCESS_CACHE_TTL_MS then
        return hasK9AccessCache.value
    end

    local result = lib.callback.await('qbx_k9unit:server:hasK9Access', false)
    hasK9AccessCache.value = result == true
    hasK9AccessCache.checkedAt = now
    return hasK9AccessCache.value
end

--- Combinator every other client file should call for K9 UI/feature
--- gating decisions. See FILE-TO-FILE CONTRACT above.
--- @return boolean
function CanShowK9UI()
    return IsOwnModelK9() and HasK9Access()
end

--- Shared denial notification for the "you cannot use K9 features right
--- now" case. Refactor pass (dedup): this exact lib.notify() call was
--- previously duplicated verbatim across client/radial.lua, client/search.lua,
--- and client/vehicle.lua (client/movement.lua and client/tracking.lua also
--- have their own copy, out of scope for this pass — left as-is). Declared
--- as a bare global here per this file's own established "declare once,
--- reuse everywhere" convention (see CanShowK9UI/IsOwnModelK9 above).
function DenyK9UIAccess()
    lib.notify({ title = 'K9 Unit', description = 'You cannot use K9 features right now.', type = 'error' })
end

-- Placeholder sound reference. SPEC.md §7 flags that "bark sounds" need
-- bundled audio asset files (bark .ogg/.wav) that do not exist anywhere in
-- this resource yet, and that there's no native "make this canine ped
-- emit a bark voice line" the way human ped speech works — this is not a
-- zero-asset feature. The full playback path (network entity resolution +
-- native call) is wired for real below so dropping in a real sound bank
-- later is a one-line constant change, not new plumbing; until a real
-- asset/soundset exists, PlaySoundFromEntity with an unrecognized sound
-- name/set is a harmless no-op (it does not error), so this is safe to
-- ship as-is rather than gating the whole handler out. Coordinate with
-- asset-pipeline-agent on where real audio files should live.
local BARK_SOUND_NAME = 'Bark'

--- Shared placeholder sound-bank name for every bark/alert-style sound
--- played on a network-resolved entity in this resource (this file's own
--- playBark handler below, and client/search.lua's contraband-alert
--- handler). Not a real shipped soundset yet — see the comment above.
local K9_SOUND_SET = 'qbx_k9unit_sounds'

--- REFACTOR_ROADMAP.md near-term item 2 ("resolve network entity
--- defensively" helper — 6 independent hand-written copies, 4 client-side
--- + 2 server-side). Resolves netId to a live, currently-streamed-in
--- entity handle on THIS client, or nil if it doesn't currently resolve to
--- anything real (not streamed in, deleted/recycled, or a bogus id).
---
--- Extracted from what were, before this pass, 3 independent client-side
--- copies of the exact same "NetworkDoesEntityExistWithNetworkId guard ->
--- NetworkGetEntityFromNetworkId -> DoesEntityExist guard" sequence:
--- PlaySoundOnNetworkEntity below (itself already the product of an
--- earlier dedup pass covering this file's playBark handler and
--- client/search.lua's playContrabandAlert handler — see that pass's own
--- comment, kept below for history), client/vehicle.lua's
--- ResolveVehicleFromState, and client/movement.lua's playDoorScratch
--- receiver. All three now call this single function instead. A 4th
--- named copy, client/search.lua's playContrabandAlert handler, already
--- goes through PlaySoundOnNetworkEntity (and therefore, transitively,
--- through this function) rather than resolving netId itself — it never
--- needed its own separate migration.
--- @param netId number
--- @return number? entity
function ResolveNetworkEntity(netId)
    if not NetworkDoesEntityExistWithNetworkId(netId) then
        return nil -- this client doesn't have the entity streamed in at all
    end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(entity) then return nil end

    return entity
end

--- Resolves netId to a live, currently-streamed-in entity and plays
--- soundName from it via this resource's shared placeholder sound set.
--- Refactor pass (dedup): this exact "resolve netId -> guard
--- DoesEntityExist -> PlaySoundFromEntity" sequence was previously
--- duplicated between this file's playBark handler and
--- client/search.lua's contraband-alert handler; the resolve half is now
--- ResolveNetworkEntity() above (REFACTOR_ROADMAP.md near-term item 2).
--- @param netId number
--- @param soundName string
function PlaySoundOnNetworkEntity(netId, soundName)
    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    PlaySoundFromEntity(-1, soundName, entity, K9_SOUND_SET, false, 0)
end

--- Plays a bark on the K9 identified by netId, for any client that has it
--- streamed in (broadcast via TriggerClientEvent(..., -1, ...) from
--- server/main.lua's relayBark handler).
--- @param netId number
--- @param barkType string
RegisterNetEvent('qbx_k9unit:client:playBark', function(netId, barkType)
    -- `barkType` is treated as an opaque passthrough string for Phase 1 —
    -- only one generic bark exists ('bark', see client/radial.lua's Bark
    -- item), so it isn't yet used to select between distinct assets.
    -- Phase 5's AdvancedBarkRadial is where per-type sound selection would
    -- get added.
    PlaySoundOnNetworkEntity(netId, BARK_SOUND_NAME)
end)
