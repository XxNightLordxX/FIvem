--[[
    qbx_k9unit/client/search.lua

    Phase 2 (coder-frontend). Owns Search Vehicle / Search Person: the two
    ox_target options that play a sniff animation, then await the server's
    real, server-computed contraband result — SPEC.md §11.1 sub-phases
    2b/2c, §11.3's `client/search.lua` row. Deliberately a SEPARATE file
    from client/tracking.lua even though both are "K9 sniffs, a result
    appears" in flavor — the split is by TRUST MODEL, not feature name:
    tracking reveals a client-cosmetic trail (no real capability granted,
    informational only per §11.6); search reveals a target's REAL,
    server-verified inventory contents (a real capability grant, the same
    trust category as certification, per §11.3's "splitting by trust
    model... mirrors how Phase 1 split certifications.lua from main.lua"
    reasoning). Do not fold this file into client/tracking.lua, and do not
    let any of tracking.lua's trail-rendering logic grow into this file.

    Supplementary implementation detail (non-authoritative — SPEC.md §11 is
    the source of truth if anything here drifts from it):
    phase2_notes/contraband_search_contract.md (the concrete ox_inventory
    export surface, validation order, and container-recursion requirement).

    ======================================================================
    EVENT/CALLBACK CONTRACT — Phase 2, per SPEC.md §11.4 item 2. Server
    side lives in server/search.lua (read directly as part of this pass —
    see the resolved bystander-alert note below).

    Callbacks (ox_lib lib.callback):
    1. 'qbx_k9unit:server:searchTarget' (targetType: 'vehicle'|'person', targetNetId: number)
       -> { ok: boolean, reason: string?, contrabandFound: boolean?, totalWeight: number?, alertTier: string? }
       [server/search.lua]
       THE SECURITY-CRITICAL CALLBACK. THIS FILE (the client side) only
       ever CONSUMES this callback's return value — it must never compute
       or pre-display a result on its own, and every field in the response
       is 100% server-computed, never an echo of anything this file sent
       (`targetType`/`targetNetId` are the only two fields THIS FILE
       controls, and only ever select WHICH entity gets checked, never the
       outcome).
       `reason` values handled below, per
       phase2_notes/contraband_search_contract.md §3 and confirmed against
       server/search.lua's own header as of this pass: 'invalid_target',
       'feature_disabled', 'no_access', 'search_in_progress', 'on_cooldown',
       'too_far', 'search_failed'. `search_failed` is shown to the player as
       distinct from a clean result ("couldn't complete the search, try
       again" — NEVER "nothing found") — collapsing the two is the exact
       correctness bug that note's §3 step 10 and §6 flag explicitly.

    RESOLVED — bystander-alert broadcast event (was an OPEN GAP in this
    file's earlier scaffold pass; SPEC.md §11.4 item 2 does not name it,
    only that it broadcasts "the same way server/main.lua's relayBark
    does"). Confirmed by reading server/search.lua's own header directly
    during this pass (that file names and documents this exact event,
    payload, and receiving file — not guessed):
    2. 'qbx_k9unit:client:playContrabandAlert' (netId: number, alertTier: string)
       [server/search.lua broadcasts; THIS FILE receives, per
       server/search.lua's own header assigning the receive side here
       rather than to client/main.lua] — deliberately carries ONLY
       netId + alertTier, NEVER totalWeight/contrabandFound (those are
       private to the requester, returned solely via the callback above,
       per §11.4 item 2's "never broadcast" language and
       contraband_search_contract.md §6's "leaking exact contraband detail
       to the wrong audience" exploit note). Distance-filtered server-side
       (Config.SearchZones.alertBroadcastRadius) — NOT a global
       TriggerClientEvent(-1, ...) like relayBark, so a no-op if this
       client never receives it (out of range of the searched target).

    No server events (client->server) for THIS FILE beyond the callback
    above — result delivery to the requester is the callback; the
    bystander broadcast is server-initiated only.
    ======================================================================

    FILE-TO-FILE CONTRACT (client side):
    - THIS FILE exposes NO resource-global functions to other client
      files. Confirmed ox_target-only, mirroring how client/vehicle.lua's
      ox_target options call that file's OWN internal logic directly
      rather than exposing a cross-file global for it. client/radial.lua
      gets no "Search Vehicle/Person" item — SPEC.md §11.5's acceptance
      criteria only ever describe ox_target as the entry point for this
      feature.
    - THIS FILE calls client/main.lua's CanShowK9UI() inside each
      ox_target option's canInteract AND again, defensively, inside
      onSelect before awaiting the callback — mirrors client/vehicle.lua's
      enterVehicle option, which is exactly the kind of "hot call site"
      client/main.lua's header names as the reason HasK9Access() carries a
      short TTL cache (canInteract can run several times a second while
      hovering).
    - THIS FILE reads Config.SearchZones (confirmed landed in config.lua as
      of this pass, including the alertBroadcastRadius amendment beyond
      §11.2's original text — that field is server/search.lua's own
      concern for filtering the broadcast, not read by this file directly).
      Config.SearchContrabandItems is NOT read by this file at all — the
      authoritative contraband list/detection lives server-side only, per
      §11.2's "single source of truth" framing; this file never duplicates
      contraband-detection logic client-side even for a preview.

    Ped/NPC search (a "person" search against a non-player ped) is
    explicitly a STRETCH item per §11.3's own scoping note, not required
    for Phase 2 — this file's player-only scope matches §11.4 item 2's
    server-side validation (NetworkGetPlayerIndexFromPed check).

    DEPENDENCY NOTE: no compile-time dependency on client/tracking.lua or
    client/vision.lua. Load order relative to those two doesn't matter.
]]

--- Local-only UX guard against double-dispatching the SAME ox_target
--- option while a previous search is still awaiting its callback (e.g. a
--- double-click before the sniff animation/progress bar visually disables
--- the option). This is a UX nicety only, NOT the security boundary —
--- server/search.lua's own in-flight mutex (per
--- phase2_notes/contraband_search_contract.md §4A) is what actually closes
--- the exploitable race; this local flag exists purely so this client
--- doesn't visibly fire two overlapping sniff animations/progress bars
--- against itself.
--- @type boolean
local searchInProgress = false

--- Shared implementation behind the two ox_target options below. Plays the
--- sniff animation/progress bar, awaits the server's authoritative result,
--- and renders feedback — never computes or guesses a result itself. Kept
--- as one function rather than two near-duplicate copies for the same
--- "textually identical acceptance criteria" reason client/tracking.lua's
--- StartTrack() helper documents for its own three callers.
--- @param targetType 'vehicle'|'person'
--- @param targetEntity number  -- resolved live entity handle from the ox_target callback's own `data.entity`
local function PerformSearch(targetType, targetEntity)
    -- Defensive re-check, same posture as every other gated action in this
    -- resource; canInteract below is a DISPLAY optimization only, the
    -- server independently re-validates HasK9Access(source) regardless
    -- (§11.4 item 2 step 3 per the contract note).
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- Silent, routine double-click protection, not an error state worth a
    -- notification (mirrors phase2_notes/contraband_search_contract.md
    -- §4's own "Rejection UX note" recommendation for
    -- on_cooldown/search_in_progress being low-key, not error-styled).
    if searchInProgress then return end

    if not DoesEntityExist(targetEntity) then
        lib.notify({ title = locale('common.notify_title'), description = locale('search.nothing_to_search'), type = 'error' })
        return
    end

    -- Resolve the netId NOW, before the sniff animation, not after. Entity
    -- handles get recycled once an entity is deleted/streamed out — if we
    -- held targetEntity raw across the full sniffAnimDurationMs delay and
    -- converted it only at the end, a target that disconnects/despawns
    -- mid-animation could have its handle reassigned to an unrelated
    -- entity by the time we call NetworkGetNetworkIdFromEntity, silently
    -- searching (and potentially broadcasting a contraband alert about)
    -- the wrong person/vehicle. Capturing it here, while targetEntity is
    -- still known-fresh from the ox_target callback that just fired,
    -- closes that window (qa-tester finding).
    local targetNetId = NetworkGetNetworkIdFromEntity(targetEntity)

    searchInProgress = true

    -- Sniff animation shell. OPEN, not resolved by SPEC.md §11 or any
    -- phase2_notes file: the exact anim/scenario native for a
    -- "sniffing/searching" pose would need the same native-api-assistant
    -- confirmation pass client/movement.lua's K9Sit() precedent already got
    -- for its WORLD_DOG_SITTING_* scenarios
    -- (phase2_notes/scent_blood_tracking.md §4's identical flag for a
    -- tracking-session sniff animation) — not guessed at here rather than
    -- risk shipping a fabricated scenario name. lib.progressBar alone still
    -- gives real UX value (pacing, a cancel/interrupt hook if the player
    -- moves away mid-sniff) even without a confirmed anim underneath it;
    -- swapping in a real scenario once confirmed is a one-line addition to
    -- this call, not new plumbing.
    local completed = lib.progressBar({
        duration = Config.SearchZones.sniffAnimDurationMs,
        label = targetType == 'vehicle' and locale('search.progress_vehicle_label') or locale('search.progress_person_label'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
    })

    if not completed then
        searchInProgress = false
        return -- player cancelled/moved away mid-sniff; no server call made at all
    end

    -- qa-tester finding: everything from the awaited callback through the
    -- result-rendering notifies below is wrapped in pcall so a throw
    -- anywhere in that span (the callback itself, or anything after it)
    -- can never leave searchInProgress stuck permanently true — mirrors
    -- the "always release/reset on every exit, success or error" posture
    -- server/search.lua's own SearchMutex already follows. searchInProgress
    -- is reset exactly once, unconditionally, after this pcall regardless
    -- of which branch inside it ran or whether it threw.
    local ok = pcall(function()
        local result = lib.callback.await('qbx_k9unit:server:searchTarget', false, targetType, targetNetId)

        if not result or not result.ok then
            local reason = result and result.reason

            if reason == 'search_failed' then
                -- Kept structurally distinct from a clean result — NEVER the
                -- same copy as contrabandFound = false, per this file's
                -- EVENT/CALLBACK CONTRACT above.
                lib.notify({ title = locale('common.notify_title'), description = locale('search.failed'), type = 'error' })
            elseif reason == 'on_cooldown' or reason == 'search_in_progress' then -- luacheck: ignore 542
                -- Low-key / no notification, per the contract note's Rejection UX note.
                -- Deliberately empty branch (silent no-op UX), not a missed implementation.
            else
                -- 'no_access', 'feature_disabled', 'too_far', 'invalid_target',
                -- or an unrecognized/missing reason: a plain error notify is
                -- fine, these are not expected to be routine traffic the way
                -- cooldown is.
                lib.notify({ title = locale('common.notify_title'), description = locale('search.generic_denied'), type = 'error' })
            end

            return
        end

        -- Render feedback purely from result.contrabandFound / result.totalWeight
        -- (private to this requester, per §11.4 item 2 — "returned ONLY to the
        -- requesting caller... never broadcast").
        if result.contrabandFound then
            -- Local success feedback for the requester only. The
            -- bystander-audible broadcast alert (if Config.Features.ContrabandAlerts)
            -- is a SEPARATE thing server/search.lua triggers independently (see
            -- this file's header's RESOLVED note on which event backs it) —
            -- this function does not (and per §11.4 item 2's "never broadcast"
            -- language, must NOT) trigger any broadcast itself from the client
            -- side.
            lib.notify({
                title = locale('common.notify_title'),
                description = locale('search.contraband_found'),
                type = 'success',
            })
        else
            -- Explicit, NON-SILENT "nothing found" notification beat — per
            -- phase2_notes/contraband_search_contract.md §5's explicit
            -- requirement ("the requester's own client must render some
            -- explicit 'nothing found' feedback... this doesn't need a server
            -- broadcast at all, since it's private feedback to the one client
            -- who asked and already has the answer in hand"). Do NOT leave
            -- this case silent.
            lib.notify({
                title = locale('common.notify_title'),
                description = locale('search.nothing_found'),
                type = 'inform',
            })
        end
    end)

    if not ok then
        -- Same "search could not be completed" copy as the search_failed
        -- branch above — from the player's perspective an unhandled throw
        -- mid-search is indistinguishable from the server reporting
        -- search_failed, so it gets the same non-silent, distinct-from-
        -- "nothing found" treatment.
        lib.notify({ title = locale('common.notify_title'), description = locale('search.failed'), type = 'error' })
    end

    searchInProgress = false
end

-- "Search Vehicle" / "Search Person" ox_target options — LIFECYCLE FIX
-- (this pass): pulled into a named function so both can be re-run any time
-- ox_target itself (re)starts, not just once at this file's own load time.
-- ox_target keeps its addGlobalVehicle/addGlobalPlayer registries in plain
-- file-local Lua tables inside its OWN client chunk (confirmed by reading
-- ox_target's client/api.lua directly), cleared only by ox_target's own
-- `onClientResourceStop` handler when the CALLING resource (this one)
-- stops — a bare `restart ox_target` while this resource keeps running
-- reloads that chunk with empty tables and nothing else asks anyone to
-- re-register. See the `AddEventHandler` immediately below for the two
-- triggers this now dispatches on, mirroring server/tracking.lua's
-- RegisterScentInventoryHook fix for the identical bug class against
-- ox_inventory. DUPLICATE-VS-REPLACE: both options below always set
-- `name`, and ox_target's own `addTarget` unconditionally removes any
-- existing option with the same name+resource before appending, so
-- re-running this never duplicates either entry.
local function RegisterSearchOxTargetOptions()
    -- "Search Vehicle" ox_target option (exports.ox_target:addGlobalVehicle,
    -- mirroring client/vehicle.lua's existing addGlobalVehicle registration
    -- shape exactly) — name 'qbx_k9unit:searchVehicle'. canInteract is a
    -- DISPLAY optimization only per SPEC.md §3/§4.5, same "not the security
    -- boundary" framing client/vehicle.lua's own header already documents for
    -- its enterVehicle option, since server/search.lua independently
    -- re-verifies everything (§11.4 item 2).
    exports.ox_target:addGlobalVehicle({
        {
            name = 'qbx_k9unit:searchVehicle',
            icon = 'fas fa-magnifying-glass',
            label = locale('search.vehicle_target_label'),
            distance = Config.SearchZones.vehicleSearchDistance,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.SearchZones then return false end
                return CanShowK9UI()
            end,
            onSelect = function(data)
                PerformSearch('vehicle', data.entity)
            end,
        },
    })

    -- "Search Person" ox_target option (exports.ox_target:addGlobalPlayer,
    -- mirroring client/movement.lua's existing addGlobalPlayer registrations,
    -- e.g. its "Attach Leash" option's shape) — name 'qbx_k9unit:searchPerson'.
    -- Self-exclusion (NetworkGetPlayerIndexFromPed(entity) ~= PlayerId()) is a
    -- low-stakes UX judgment call, not addressed one way or the other by
    -- SPEC.md §11 — mirrors the self-exclusion already established for the
    -- leash and certify/revoke ox_target options in client/movement.lua;
    -- server/search.lua's own proximity + entity-type checks make a
    -- self-search harmless even if attempted.
    -- Ped/NPC variant (non-player peds) is an explicit STRETCH item per §11.3
    -- — no addGlobalPed/addModel registration added here, since
    -- server/search.lua's contract only validates a real connected player's
    -- ped for targetType == 'person'.
    exports.ox_target:addGlobalPlayer({
        {
            name = 'qbx_k9unit:searchPerson',
            icon = 'fas fa-magnifying-glass',
            label = locale('search.person_target_label'),
            distance = Config.SearchZones.personSearchDistance,
            canInteract = function(entity, distance, coords, name)
                if not Config.Features.SearchZones then return false end
                if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't search self
                return CanShowK9UI()
            end,
            onSelect = function(data)
                PerformSearch('person', data.entity)
            end,
        },
    })
end

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() or resourceName == 'ox_target' then
        RegisterSearchOxTargetOptions()
    end
end)

-- Bystander-audible contraband alert broadcast receiver. Mirrors
-- client/main.lua's existing playBark handler exactly (resolve the network
-- entity, no-op if not streamed in, play a sound) — see this file's header
-- for why the receive side lands here rather than in client/main.lua
-- (server/search.lua's own header explicitly assigns it to this file).
-- `alertTier` is one of Config.ContrabandAlertTiers' `alert` strings (e.g.
-- 'whine' / 'aggressive_bark') — deliberately never the requester's private
-- totalWeight/contrabandFound (those never leave the callback above).
RegisterNetEvent('qbx_k9unit:client:playContrabandAlert', function(netId, alertTier)
    -- SOURCE-ORIGIN GUARD (coder-security pass — see client/combat.lua's
    -- own "SOURCE-ORIGIN GUARD" header block for the full sourced
    -- writeup/confidence grading, not re-derived here). Cosmetic-only
    -- payoff (a forged call just plays a sound naming an arbitrary
    -- alertTier string at an arbitrary netId), applied for resource-wide
    -- consistency with every other `qbx_k9unit:client:*` handler, not
    -- because this one carries real exploit severity on its own.
    if source ~= 65535 then return end
    -- Reuses the same placeholder sound-bank plumbing client/main.lua's
    -- playBark handler already establishes (SPEC.md §7: bark/alert audio
    -- needs bundled asset files that don't exist in this resource yet;
    -- PlaySoundFromEntity with an unrecognized sound name/set is a harmless
    -- no-op, not an error, so this is safe to ship ahead of real assets).
    -- `alertTier` is passed straight through as the sound name — 'clean'
    -- deliberately produces no meaningful sound today (no asset mapped),
    -- which is fine since a 'clean' result's requester-side feedback is
    -- already fully covered by PerformSearch()'s own local notify above;
    -- whether 'clean' should ALSO broadcast for bystander symmetry is a
    -- server/search.lua decision (contraband_search_contract.md §5), not
    -- something this receiver needs to special-case either way.
    PlaySoundOnNetworkEntity(netId, alertTier)
end)
