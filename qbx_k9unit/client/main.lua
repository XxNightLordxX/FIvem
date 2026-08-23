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
      used by client/movement.lua, client/radial.lua, and client/vehicle.lua:
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

--- Pure client-side, display-only check: is the local player's OWN
--- character currently a recognized K9 model? Never used for security —
--- see SPEC.md §4.5 ("Convenience (client)" bullet).
--- TODO(coder-frontend): build a hash set from Config.Peds once (mirror
--- server/certifications.lua's K9ModelHashes approach so both sides stay
--- generic over the config, no hardcoded model name anywhere — SPEC.md §3
--- acceptance bullet 3), then compare GetEntityModel(PlayerPedId()).
--- @return boolean
function IsOwnModelK9()
    return false
end

-- TODO(coder-frontend): lightweight cache for HasK9Access() below — e.g.
-- a module-local `{ value: boolean, checkedAt: number }` with a ~1000ms
-- TTL (GetGameTimer()-based), so a hot call site (ox_target canInteract
-- predicates in client/vehicle.lua and client/movement.lua's leash
-- option, in particular) doesn't re-await the server callback on every
-- hover frame. Keep the TTL short enough that "checked... not just once"
-- (SPEC.md §4.1) still holds in spirit — this is a debounce, not a
-- permanent cache.

--- Awaits the server's authoritative access check for the LOCAL player.
--- @return boolean
function HasK9Access()
    -- TODO(coder-frontend): return lib.callback.await('qbx_k9unit:server:hasK9Access', false)
    -- (through the TTL cache described above once it exists).
    return false
end

--- Combinator every other client file should call for K9 UI/feature
--- gating decisions. See FILE-TO-FILE CONTRACT above.
--- @return boolean
function CanShowK9UI()
    return IsOwnModelK9() and HasK9Access()
end

--- Plays a bark on the K9 identified by netId, for any client that has it
--- streamed in (broadcast via TriggerClientEvent(..., -1, ...) from
--- server/main.lua's relayBark handler).
--- @param netId number
--- @param barkType string
RegisterNetEvent('qbx_k9unit:client:playBark', function(netId, barkType)
    -- TODO(coder-frontend): guard with
    -- NetworkDoesEntityExistWithNetworkId(netId) (this client may not have
    -- the ped streamed in at all), resolve the entity via
    -- NetworkGetEntityFromNetworkId(netId), then PlaySoundFromEntity (or
    -- equivalent) using an asset keyed by barkType. Phase 1 only needs one
    -- generic bark asset (see client/radial.lua's Bark item for the
    -- literal barkType string it sends — keep both ends in sync). SPEC.md
    -- §7 notes bark sounds need bundled audio asset files (not
    -- zero-asset) — coordinate with asset-pipeline-agent on where those
    -- files live if they don't exist yet.
end)
