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
      PlaySoundOnNetworkEntity below — REFACTOR_ROADMAP.md near-term item 2),
      PLUS ResolvePlayerServerIdFromPed() and IsEntityModelK9() (see their
      own doc comments below — REFACTOR_ROADMAP.md item 2b and item 3
      respectively):
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

--- Is `entity`'s current model one of Config.Peds' recognized K9 models?
--- Client-side, display/targeting-plausibility only — NEVER a security
--- boundary; every server-side handler that cares about a target's real
--- model re-derives it itself (IsConfiguredK9Model, server/certifications.lua).
---
--- REFACTOR_ROADMAP.md item 3. Promoted from client/movement.lua's local
--- `IsEntityModelK9`/`k9ModelHashesForTargeting` pair (which already had
--- this exact signature) to a resource-global here, reusing THIS file's
--- own `K9ModelHashes` table above rather than building a second,
--- identical one — the Revision 5 audit found this same boolean
--- model-recognition table independently hand-copied 6 times across this
--- resource (client/main.lua, client/movement.lua, client/wellbeing.lua,
--- client/medkit.lua, client/inventory.lua, and client/partnership.lua —
--- this last one a previously untracked 6th instance found only while
--- consolidating the other five). This is now fully done, landed across
--- two passes: the first deleted the client/movement.lua/client/wellbeing.lua/
--- client/medkit.lua copies; a later pass deleted the remaining
--- client/inventory.lua and client/partnership.lua copies too, once each
--- was re-read and confirmed byte-identical in behavior (same
--- Config.Peds-driven model set, no extra guard/nil-check divergence) —
--- see those two files' own call sites for the direct
--- `IsEntityModelK9(entity)` calls that replaced them. Zero duplicate
--- copies of this check remain anywhere in `client/` as of this comment;
--- if a new one appears, update this count rather than letting it go
--- unrecorded again.
--- server/certifications.lua's server-side `K9ModelHashes` is correctly
--- left alone per the roadmap's own note — a resource-global here can't
--- cross the client/server realm boundary.
--- @param entity number
--- @return boolean
function IsEntityModelK9(entity)
    return K9ModelHashes[GetEntityModel(entity)] == true
end

--- Pure client-side, display-only check: is the local player's OWN
--- character currently a recognized K9 model? Never used for security —
--- see SPEC.md §4.5 ("Convenience (client)" bullet).
--- @return boolean
function IsOwnModelK9()
    return IsEntityModelK9(PlayerPedId())
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
--- client/vehicle.lua, client/movement.lua, and client/tracking.lua. All five
--- have since been migrated to call this shared function directly.
--- FOUR raw copies still remain and are NOT yet migrated, counted by
--- reading rather than grepping: client/agility.lua:240, and
--- client/movement.lua at 328, 1312 and 1424. An earlier revision of this
--- comment claimed zero remained; that was wrong. Update the count here
--- when you migrate one, rather than letting it drift again. Declared as a bare global here per this file's own
--- established "declare once, reuse everywhere" convention (see
--- CanShowK9UI/IsOwnModelK9 above).
function DenyK9UIAccess()
    lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
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

--- Phase 5 (Config.Features.AdvancedBarkRadial, client/radial.lua): maps a
--- specific `barkType` string (config.lua's Config.AdvancedBarkRadial —
--- SPEC.md §6.7's "aggressive/alert/calm") to its own placeholder sound
--- name, built once at file load. Still all placeholder audio, same
--- K9_SOUND_SET convention as BARK_SOUND_NAME above — phase2_notes/
--- phase5_features_research.md §1 confirms a real per-variant soundset
--- needs authored `.awc`/REL audio-bank assets, not just a different string
--- here; this table only carries the plumbing. Built defensively against
--- Config.AdvancedBarkRadial not existing (older configs, or the feature
--- flag simply left off) since this table is populated unconditionally
--- regardless of Config.Features.AdvancedBarkRadial's value.
local BarkTypeSoundNames = {}
for _, variant in ipairs(Config.AdvancedBarkRadial or {}) do
    BarkTypeSoundNames[variant.barkType] = variant.sound
end

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

--- Resolves a targeted ped entity to the server id of the player it
--- belongs to, or nil if it isn't (currently) a real player's own ped.
--- CLIENT-SIDE ONLY — NetworkGetPlayerIndexFromPed + GetPlayerServerId is
--- the standard, well-established client-side combo for this.
--- server/entities.lua's own ResolveConnectedPlayerFromPed doc comment
--- flags this SAME native combo as unverified SERVER-side only; that
--- caveat does not apply to this client-side use.
---
--- REFACTOR_ROADMAP.md item 2b. Extracted from two independent,
--- byte-identical hand-written copies of this exact function:
--- client/medkit.lua's "Treat K9" onSelect handler and
--- client/wellbeing.lua's "Pet K9"/"Feed K9" onSelect handlers. Both now
--- call this single function instead.
--- @param entity number
--- @return number? targetServerId
function ResolvePlayerServerIdFromPed(entity)
    local playerIndex = NetworkGetPlayerIndexFromPed(entity)
    if playerIndex == -1 then return nil end

    local targetServerId = GetPlayerServerId(playerIndex)
    if not targetServerId or targetServerId == 0 then return nil end

    return targetServerId
end

--- Resolves netId to a live, currently-streamed-in entity and plays
--- soundName from it via this resource's shared placeholder sound set.
--- Refactor pass (dedup): this exact "resolve netId -> guard
--- DoesEntityExist -> PlaySoundFromEntity" sequence was previously
--- duplicated between this file's playBark handler and
--- client/search.lua's contraband-alert handler; the resolve half is now
--- ResolveNetworkEntity() above (REFACTOR_ROADMAP.md near-term item 2).
---
--- Two playback paths run back-to-back, not either/or: the original
--- PlaySoundFromEntity native call stays exactly as it was (a harmless
--- no-op today against this resource's placeholder K9_SOUND_SET, ready to
--- start doing something the moment an operator ships a real RAGE audio
--- bank under that soundset name — see BARK_SOUND_NAME's own comment
--- above), immediately followed by client/audio.lua's PlayK9Sound NUI
--- bridge, which is the one that can actually make sound today if an
--- operator has dropped a matching .ogg into html/sounds/ (see that
--- file's header). PlayK9Sound is guarded with a `type(...) == 'function'`
--- existence check rather than called unconditionally: client/audio.lua
--- returns without defining it at all when Config.Features.
--- BasicBarkSounds is false, so the global genuinely may not exist (same
--- runtime-existence-guard convention config.lua's globals comment already
--- documents for RestoreInjury/AwardXP/GetXPTier). soundName here is
--- always either BARK_SOUND_NAME or a Config.AdvancedBarkRadial-authored
--- entry from BarkTypeSoundNames below — never a raw caller-supplied
--- string — so this passes PlayK9Sound the exact same trusted,
--- table-lookup-only value already trusted to reach PlaySoundFromEntity,
--- and PlayK9Sound's own ToAudioFileKey() never turns that into anything
--- more than a lookup/best-effort-transform of that already-trusted
--- string, not an arbitrary filename from player input. If no matching
--- .ogg has been shipped (true for every default install today, per this
--- resource's html/sounds/CREDITS.md), client/audio.lua's own contract
--- guarantees this degrades to a silent, zero-console-output no-op end to
--- end, same as the native call it sits beside.
--- @param netId number
--- @param soundName string
function PlaySoundOnNetworkEntity(netId, soundName)
    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    PlaySoundFromEntity(-1, soundName, entity, K9_SOUND_SET, false, 0)

    if type(PlayK9Sound) == 'function' then
        PlayK9Sound(netId, soundName)
    end
end

--- Plays a bark on the K9 identified by netId, for any client that has it
--- streamed in (broadcast via TriggerClientEvent(..., -1, ...) from
--- server/main.lua's relayBark handler).
--- @param netId number
--- @param barkType string
RegisterNetEvent('qbx_k9unit:client:playBark', function(netId, barkType)
    -- SOURCE-ORIGIN GUARD (coder-security -- see client/combat.lua's
    -- "SOURCE-ORIGIN GUARD" header block and
    -- phase2_notes/client_event_trust_boundary.md for the full writeup;
    -- not re-derived here). Confidence: MEDIUM-HIGH, the official
    -- documented pattern for distinguishing a genuine server-sent event
    -- from a local self-trigger, not independently verified in-engine
    -- this pass. Note this is NOT a feature-flag gate (this file's own
    -- header already establishes BasicBarkSounds/AdvancedBarkRadial are
    -- not the "ships false, must be inert" class this resource's other
    -- gates protect -- forging this just plays a placeholder sound on
    -- whatever entity the supplied netId resolves to, via the same
    -- ResolveNetworkEntity() guard every caller of PlaySoundOnNetworkEntity
    -- already goes through).
    if source ~= 65535 then return end

    -- `barkType` is an opaque passthrough string from server/main.lua's
    -- relayBark handler (untouched by this feature — it never validates or
    -- interprets barkType itself, only length-caps it). Phase 1's single
    -- literal ('bark', client/radial.lua's non-AdvancedBarkRadial Bark item)
    -- won't be in BarkTypeSoundNames, so it falls back to the one generic
    -- BARK_SOUND_NAME below, same behavior as before this feature existed.
    -- Phase 5's AdvancedBarkRadial variants (client/radial.lua's bark
    -- submenu) DO resolve to their own distinct entry via
    -- Config.AdvancedBarkRadial (config.lua) — still placeholder audio
    -- either way, see BarkTypeSoundNames' own comment above.
    local soundName = BarkTypeSoundNames[barkType] or BARK_SOUND_NAME
    PlaySoundOnNetworkEntity(netId, soundName)
end)
