--[[
    qbx_k9unit/client/movement.lua

    Phase 1 scaffold (coder-architect). Owns everything about the K9
    player's own body: the camera toggle, the "Sit" self-emote, and the
    two-player leash mechanic in full (consent handshake, the elastic
    movement restriction while attached, and zero-consent detach). Native
    run/jump/crouch locomotion needs no wrapper code — it's inherent to
    the ped model — so it isn't stubbed here beyond the AgilityBasicJump
    note near the bottom.

    ======================================================================
    EVENT/CALLBACK CONTRACT — certification events are documented in full
    in server/certifications.lua / client/main.lua (kept in sync manually,
    not re-duplicated here). THIS FILE owns the client side of the leash
    subsystem, documented in full in server/main.lua's header — read that
    file together with this one for the complete picture. Summary of what
    THIS FILE registers/triggers:

    Server events (client->server):
    - 'qbx_k9unit:server:requestLeashAttach' (targetServerId: number)
    - 'qbx_k9unit:server:respondLeashAttach' (fromServerId: number, accepted: boolean)
    - 'qbx_k9unit:server:detachLeash' ()

    Client events (server->client):
    - 'qbx_k9unit:client:leashAttachRequest' (fromServerId: number) [THIS FILE]
    - 'qbx_k9unit:client:leashAttached' (partnerServerId: number, isConstrained: boolean) [THIS FILE]
    - 'qbx_k9unit:client:leashDetached' (reason: string) [THIS FILE]
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes resource-global (no `local`) functions consumed by
      client/radial.lua:
        ToggleK9Camera()
        K9Sit()
        RequestLeashAttach(targetPlayerServerId: number)  -- was named
            AttachLeash() in the earlier (pre-consent) scaffold draft;
            renamed because it no longer attaches anything by itself, it
            only sends a request.
        DetachLeash()
        IsLeashed() -> boolean
    - THIS FILE calls client/main.lua's global CanShowK9UI() before
      initiating a request (radial.lua is also expected to gate
      visibility, but per SPEC.md §3's "must not be triggerable by a
      modified client" spirit, don't rely solely on the caller having
      already checked — and the server re-validates independently anyway,
      see server/main.lua's CheckLeashEligibility).
    - THIS FILE registers the "Attach Leash" ox_target option on nearby
      player peds (the SPEC.md §6.1 leash bullet's "either the K9 or a
      nearby officer initiates 'Attach Leash' (ox_target) on the other").
      client/vehicle.lua owns the vehicle ox_target option instead; keep
      that split — this file should never touch vehicles, vehicle.lua
      should never touch leash/ox_target-on-peds.
    - client/radial.lua's "Attach/Detach Leash" item is a context-sensitive
      SELF-initiated alternative entry point: if not IsLeashed(), it finds
      a nearby candidate and calls RequestLeashAttach(candidateServerId);
      if IsLeashed(), it calls DetachLeash(). Both surfaces (ox_target and
      radial) end up calling the SAME two functions — don't let a second,
      divergent leash-request code path grow in radial.lua.
    - THIS FILE also registers the "Certify K9 Handler" / "Revoke K9
      Certification" ox_target options on nearby player peds (SPEC.md
      §4.3's flow table, §8 step 3 — the previously-missing entry point;
      the events themselves were always reachable via /k9certify /
      /k9decertify). These directly TriggerServerEvent the two events
      documented in full in server/certifications.lua's header
      ('qbx_k9unit:server:certifyHandler' / '...:revokeHandler', both
      (targetServerId: number)) — no new client-side contract of THIS
      FILE's own is introduced, just another entry point into that
      existing, unchanged server contract. Mirrors the "Attach Leash"
      option's structure directly (display-only plausibility gate via
      IsEntityModelK9, server re-validates everything authoritatively).

    LEASH SUBSYSTEM DESIGN (per requester's confirmation, resolving
    SPEC.md §9 item 3b — see server/main.lua's header for the full
    rationale, repeated here only as it affects THIS file):
    1. Attach requires consent — RequestLeashAttach() only ever sends a
       request; the actual pairing is formed server-side after the OTHER
       player accepts via the ox_lib prompt this file shows them.
    2. While attached, the CONSTRAINED party (always the K9-role side,
       server-assigned — see leashAttached's `isConstrained` flag) runs an
       elastic pull-back on THEIR OWN ped as they approach
       Config.LeashMaxDistance from their partner. This must run on the
       constrained player's own client because a client can only reliably
       control its own ped's position — you cannot dependably force
       another client's ped to a position from here, their own game
       instance keeps simulating and re-networking their own movement.
    3. DetachLeash() must work at ANY time for EITHER role, no
       confirmation/consent step of its own — hard requirement, no trapped
       state.
    4. If the elastic pull-back still can't keep distance under control
       (disconnect, teleport, desync) and a hard cap is exceeded, the
       CONSTRAINED client calls DetachLeash() itself as a safety valve —
       reuse this exact function, don't build a second detach code path.
]]

-- Local-only view-mode state for the camera toggle below. Not exposed —
-- ToggleK9Camera() is the only entry point.
local isFirstPersonK9View = false

--- Toggles first/third-person camera at the K9's eye height while playing
--- a K9 character. See client/main.lua's OPEN QUESTION about whether this
--- needs to be gated by CanShowK9UI() at all — per this scaffold's lean
--- (and the top-level task's explicit direction) this does NOT gate on
--- CanShowK9UI() (a QoL toggle, not a granted capability); it DOES gate on
--- the cheap, local, free IsOwnModelK9() check, since "while playing their
--- K9 character" (SPEC.md §6.1 bullet 2) implies it's meaningless for a
--- human-model character, not that it requires job/cert.
--- SPEC.md §6.1 bullet 2, §8 step 5. Bound to a rebindable keymapping
--- (FiveM's own Settings > Key Bindings screen lets a player/server change
--- the default) rather than a radial item — camera toggle isn't in the
--- Phase 1 radial item list (Bark/Sit/Leash/Vehicle only, see
--- client/radial.lua), so it needs its own input path.
--- SetFollowPedCamViewMode drives the game's OWN built-in first/third
--- person camera system, which already derives eye/vantage height from
--- the CURRENT ped model's actual skeleton (including quadruped models)
--- generically — this is why no manual CreateCam/AttachCamToEntity rig is
--- needed to satisfy "camera at the dog's eye height": the native camera
--- modes already do that for any ped model without per-model tuning.
function ToggleK9Camera()
    if not IsOwnModelK9() then
        lib.notify({ title = 'K9 Unit', description = 'This only works while playing a K9 character.', type = 'error' })
        return
    end

    isFirstPersonK9View = not isFirstPersonK9View
    SetFollowPedCamViewMode(isFirstPersonK9View and 4 or 1)
    lib.notify({
        title = 'K9 Unit',
        description = isFirstPersonK9View and 'First-person view.' or 'Third-person view.',
        type = 'inform',
    })
end

RegisterCommand('qbx_k9unit:toggleCamera', function()
    ToggleK9Camera()
end, false)

RegisterKeyMapping('qbx_k9unit:toggleCamera', 'Toggle K9 First/Third Person Camera', 'keyboard', 'L')

--- Self-emote "Sit" action triggered from the radial menu. SPEC.md §6.1
--- radial bullet, §8 step 7. Gated with CanShowK9UI() at the top (per
--- radial.lua's own contract, every Phase 1 radial item is a real granted
--- capability check, unlike camera/locomotion above) — return early (and
--- notify) if false, don't just rely on radial.lua having already hidden
--- the item.
--- VERIFIED (native-api-assistant pass, 2026-08-23): "WORLD_DOG_SIT" (the
--- earlier scaffold's guess) is NOT a real scenario — there is no generic
--- dog-sit scenario name at all. Cross-checked against two independently
--- maintained community scenario dumps (DioneB/GTAV-Scenarios and
--- kibook/spooner's scenarios.lua, both decompiled-game-data-derived lists
--- that agree exactly on the dog entries), the real names are PER-BREED:
---   WORLD_DOG_SITTING_SHEPHERD / _ROTTWEILER / _RETRIEVER / _SMALL
--- (plus WORLD_DOG_BARKING_* siblings, not used here). Confidence: HIGH on
--- these exact strings existing (two independent authoritative-for-FiveM-
--- purposes sources agree); MEDIUM on the breed-to-scenario mapping below
--- for a_c_chop/a_c_huskie specifically, since neither has an exact-name
--- match and dog scenario anims are shared across the generic quadruped
--- skeleton rather than being model-locked — untested in-engine this
--- session, so if a mapped breed looks visibly off, that's the first
--- place to revisit. TaskStartScenarioInPlace on a PLAYER-controlled ped
--- (vs. an AI ped) is expected/normal here: same native, it plays the pose
--- and exits automatically the moment the player provides movement input,
--- which is the desired "self-emote until you move" behavior for this
--- radial item, not a bug — no anim-dict/TaskPlayAnim fallback is needed
--- since a real scripted scenario exists for every configured breed.
--- Precomputed model-hash -> scenario lookup, built once at file load.
--- Mirrors the precomputed-hash-table convention already used elsewhere
--- in this codebase (client/main.lua's K9ModelHashes, this file's own
--- k9ModelHashesForTargeting) rather than calling GetHashKey per lookup.
local K9_SIT_SCENARIO_BY_MODEL_HASH = {}
for model, scenario in pairs({
    a_c_shepherd = 'WORLD_DOG_SITTING_SHEPHERD',
    a_c_rottweiler = 'WORLD_DOG_SITTING_ROTTWEILER',
    a_c_chop = 'WORLD_DOG_SITTING_ROTTWEILER', -- Chop is Rottweiler-framed; no Chop-specific scenario exists
    a_c_huskie = 'WORLD_DOG_SITTING_RETRIEVER', -- no husky-specific scenario; RETRIEVER is the closest general/medium-dog sit
}) do
    K9_SIT_SCENARIO_BY_MODEL_HASH[GetHashKey(model)] = scenario
end
local K9_SIT_DEFAULT_SCENARIO = 'WORLD_DOG_SITTING_SHEPHERD' -- fallback if playing an unmapped/future Config.Peds model

function K9Sit()
    if not CanShowK9UI() then
        lib.notify({ title = 'K9 Unit', description = 'You cannot use K9 features right now.', type = 'error' })
        return
    end

    local ped = PlayerPedId()
    local scenarioName = K9_SIT_SCENARIO_BY_MODEL_HASH[GetEntityModel(ped)] or K9_SIT_DEFAULT_SCENARIO

    ClearPedTasksImmediately(ped)
    TaskStartScenarioInPlace(ped, scenarioName, 0, true)
end

--- Local-only UI/role bookkeeping for the CURRENT leash pairing, if any.
--- The pairing's existence is server-authoritative (server/main.lua's
--- LeashPairs); this is just this client's cached view of it, refreshed
--- by the leashAttached/leashDetached handlers below. Not exposed
--- directly — always go through IsLeashed()/DetachLeash().
--- @type { partnerServerId: number, isConstrained: boolean }|nil
local leashState = nil

--- Guards the hard-cap safety-valve branch below from firing more than
--- once per attach: the pull-back thread ticks every LEASH_TICK_MS, so
--- under latency the server's detach round-trip can take longer than one
--- tick, and without this flag the branch would re-fire and duplicate the
--- notification/DetachLeash() call every tick until leashState actually
--- clears. Reset in the leashAttached/leashDetached handlers below.
local detachRequestedForSafety = false

--- @return boolean
function IsLeashed()
    return leashState ~= nil
end

--- Sends a leash request to `targetPlayerServerId`. Does NOT attach
--- anything by itself — see leashAttached event handler below for where
--- the pairing actually activates, after the target accepts.
--- @param targetPlayerServerId number
function RequestLeashAttach(targetPlayerServerId)
    -- Re-check, don't trust that the caller (ox_target predicate or
    -- radial item) already verified this — cheap client-side sanity check
    -- before bothering the server (which re-validates authoritatively
    -- regardless, see server/main.lua's CheckLeashEligibility).
    if not CanShowK9UI() then
        lib.notify({ title = 'K9 Unit', description = 'You cannot use K9 features right now.', type = 'error' })
        return
    end

    if IsLeashed() then
        lib.notify({ title = 'K9 Unit', description = 'You are already leashed.', type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestLeashAttach', targetPlayerServerId)
    -- The target's client is the one that shows the actual accept/decline
    -- prompt (see leashAttachRequest below), not this one.
    lib.notify({ title = 'K9 Unit', description = 'Leash request sent.', type = 'inform' })
end

--- Detaches the current leash, if any, with ZERO consent required from
--- the other party. No-op (locally and server-side) if not currently
--- leashed. This is the SAME function the elastic-restriction safety
--- valve calls automatically — see the CreateThread below.
function DetachLeash()
    if not IsLeashed() then return end

    -- Let the server-authoritative leashDetached broadcast (handled
    -- below) be what actually clears leashState/stops the thread, rather
    -- than clearing local state immediately here, so this client's view
    -- stays in sync with whatever the server decides.
    TriggerServerEvent('qbx_k9unit:server:detachLeash')
end

--- Step 1 of the consent handshake, received on the TARGET's client.
--- @param fromServerId number
RegisterNetEvent('qbx_k9unit:client:leashAttachRequest', function(fromServerId)
    local fromPlayer = GetPlayerFromServerId(fromServerId)
    local fromName = (fromPlayer ~= -1 and GetPlayerName(fromPlayer)) or ('Officer #' .. fromServerId)

    -- If the local player leashes/unleashes/disconnects mid-prompt, or
    -- either side is no longer eligible by the time they answer, the
    -- server re-validates everything at accept time regardless (see
    -- server/main.lua's CheckLeashEligibility TOCTOU note) — this client
    -- just needs to send the response and handle a later rejection
    -- gracefully, not assume acceptance always succeeds.
    local response = lib.alertDialog({
        header = 'K9 Leash Request',
        content = ('%s wants to attach a leash to you. Accept?'):format(fromName),
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })

    TriggerServerEvent('qbx_k9unit:server:respondLeashAttach', fromServerId, response == 'confirm')
end)

--- Step 2 of the consent handshake: the server has confirmed the pairing
--- and told THIS client its role. Sent individually to each party with
--- their own `isConstrained` value — do not assume both clients receive
--- the same boolean.
--- @param partnerServerId number
--- @param isConstrained boolean  -- true only on the K9-role party's client
RegisterNetEvent('qbx_k9unit:client:leashAttached', function(partnerServerId, isConstrained)
    leashState = { partnerServerId = partnerServerId, isConstrained = isConstrained }
    detachRequestedForSafety = false
    lib.notify({
        title = 'K9 Unit',
        description = isConstrained and 'You are now leashed.' or 'You are now anchoring the leash.',
        type = 'success',
    })
    -- The elastic-restriction thread below is a perpetual loop that reads
    -- `leashState` fresh every iteration, so simply setting it here is
    -- sufficient to "wake" the tighter-interval pulling behavior on the
    -- constrained client — no separate thread-start call needed.
end)

--- The pairing has ended — manual detach by either side, the constrained
--- client's own safety valve, or a partner disconnect (server/main.lua's
--- playerDropped cleanup). Sent to whichever client(s) are still around.
--- @param reason string  -- e.g. 'detached' | 'partner_disconnected'
RegisterNetEvent('qbx_k9unit:client:leashDetached', function(reason)
    leashState = nil
    detachRequestedForSafety = false

    local description = 'Leash detached.'
    if reason == 'partner_disconnected' then
        description = 'Leash detached — your partner disconnected.'
    end
    lib.notify({ title = 'K9 Unit', description = description, type = 'inform' })
    -- The elastic-restriction thread below naturally stops doing anything
    -- once IsLeashed() is false — nothing else to tear down here.
end)

-- Elastic movement-restriction thread — the part of the leash mechanic
-- that must be an actual constraint, not a passive monitor. Only does
-- anything while IsLeashed() AND leashState.isConstrained is true (the
-- anchor/officer side does nothing here beyond having already received
-- its own notify above). Re-resolves the partner ped from
-- leashState.partnerServerId every tick rather than caching the handle,
-- since a cached ped handle can go stale across a respawn/reconnect.
local LEASH_TICK_MS = 250
local LEASH_IDLE_TICK_MS = 1000
local LEASH_PULL_ZONE_FACTOR = 0.75 -- start elastic pull-back at 75% of Config.LeashMaxDistance
local LEASH_HARD_CAP_FACTOR = 1.5   -- safety-valve auto-detach threshold, relative to Config.LeashMaxDistance
local LEASH_PULL_EASE = 0.20        -- fraction of the excess distance corrected per tick (feel/tuning knob)

CreateThread(function()
    while true do
        local sleepMs = LEASH_IDLE_TICK_MS

        if leashState and leashState.isConstrained then
            sleepMs = LEASH_TICK_MS

            local partnerPlayer = GetPlayerFromServerId(leashState.partnerServerId)
            local partnerPed = partnerPlayer ~= -1 and GetPlayerPed(partnerPlayer) or 0

            if partnerPed ~= 0 and DoesEntityExist(partnerPed) then
                local myPed = PlayerPedId()
                local myCoords = GetEntityCoords(myPed)
                local partnerCoords = GetEntityCoords(partnerPed)
                local dist = #(myCoords - partnerCoords)

                local softLimit = Config.LeashMaxDistance
                local hardCap = softLimit * LEASH_HARD_CAP_FACTOR
                local pullZoneStart = softLimit * LEASH_PULL_ZONE_FACTOR

                if dist >= hardCap then
                    -- Safety-valve fallback (point 4 in this file's
                    -- header): the elastic pull-back below couldn't keep
                    -- distance under control (disconnect/teleport/desync).
                    -- Reuse the exact same detach path, don't build a
                    -- second one. Guarded so this only fires once per
                    -- attach — the server round-trip can outlast one tick
                    -- under latency, and leashState doesn't clear until
                    -- the server confirms via leashDetached.
                    if not detachRequestedForSafety then
                        detachRequestedForSafety = true
                        lib.notify({ title = 'K9 Unit', description = 'Leash snapped — you got too far from your handler.', type = 'error' })
                        DetachLeash()
                    end
                elseif dist > pullZoneStart and not IsPedInAnyVehicle(myPed, false) then
                    -- Proportional soft pull-back, not a hard snap at the
                    -- exact threshold: the closer to hardCap, the stronger
                    -- the correction applied this tick. Skipped while in a
                    -- vehicle to avoid teleporting a seated ped out from
                    -- under itself — a defensive edge case, not spelled
                    -- out in SPEC.md.
                    local excess = dist - pullZoneStart
                    local zoneSize = math.max(hardCap - pullZoneStart, 0.1)
                    local pullFactor = math.min(excess / zoneSize, 1.0)
                    local pullAmount = excess * pullFactor * LEASH_PULL_EASE
                    local dir = (partnerCoords - myCoords) / dist
                    local newCoords = myCoords + dir * pullAmount
                    SetEntityCoords(myPed, newCoords.x, newCoords.y, newCoords.z, false, false, false, true)
                end
            end
            -- If the partner ped isn't resolvable this tick (streamed
            -- out/not yet loaded), just skip pulling for now — a real
            -- disconnect is independently handled by server/main.lua's
            -- playerDropped cleanup broadcasting leashDetached.
        end

        Wait(sleepMs)
    end
end)

-- Client-side hash set for the leash ox_target option's display-only
-- plausibility check below. client/main.lua only exposes IsOwnModelK9()
-- (not its private model-hash table) per its documented three-function
-- contract, so this is a small local copy of the same generic
-- Config.Peds-driven check for THIS file's own convenience use — not a
-- security check, so a second small local copy (vs. expanding
-- client/main.lua's contract) is an acceptable, deliberate tradeoff here.
local k9ModelHashesForTargeting = {}
for _, pedEntry in ipairs(Config.Peds) do
    k9ModelHashesForTargeting[GetHashKey(pedEntry.model)] = true
end

local function IsEntityModelK9(entity)
    return k9ModelHashesForTargeting[GetEntityModel(entity)] == true
end

-- Register the "Attach Leash" ox_target option on nearby player peds
-- (SPEC.md §6.1 leash bullet's "either the K9 or a nearby officer
-- initiates 'Attach Leash' (ox_target) on the other"). This is a DISPLAY
-- optimization only — the server independently re-validates everything
-- for real in CheckLeashEligibility (server/main.lua), so this predicate
-- doesn't need to be perfect.
exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:attachLeash',
        icon = 'fas fa-link',
        label = 'Attach Leash',
        distance = 2.5,
        canInteract = function(entity, distance, coords, name)
            if not Config.Features.LeashMechanics then return false end
            if IsLeashed() then return false end
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't target self

            -- At least one side should plausibly be a K9 (either us, or
            -- the target's live model) — cheap client-side plausibility
            -- only, per this file's header note not to over-invest here.
            return IsOwnModelK9() or IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            RequestLeashAttach(GetPlayerServerId(targetPlayer))
        end,
    },
})

-- Register the "Certify K9 Handler" / "Revoke K9 Certification" ox_target
-- options on nearby player peds (SPEC.md §4.3's flow table, §8 step 3 —
-- this is the gap integration-verifier flagged: the server-side grant/
-- revoke system in server/certifications.lua was fully implemented and
-- correct, but was only reachable via /k9certify [id] / /k9decertify [id],
-- never through any in-world interaction). Mirrors the "Attach Leash"
-- option's structure immediately above: DISPLAY-ONLY plausibility gates
-- here, the server independently re-validates granter eligibility
-- (IsEligibleCertifier), proximity (Config.CertifyProximityMeters), and
-- (grant-only) the target's live model in GrantCertification /
-- RevokeCertification — see server/certifications.lua's header for the
-- full contract and its quoted SPEC.md §4.3 security note. Deliberately
-- does NOT attempt to check "is the local player an eligible certifier"
-- client-side: IsEligibleCertifier is a server-only check with no cheap
-- client-side equivalent (it reads qbx_core job/grade data this client
-- doesn't have), and a new callback purely to gate visibility isn't worth
-- adding here — showing the option broadly (to any player near a
-- K9-modeled ped) and letting the server accept-or-reject-with-notification
-- is the exact same tradeoff the leash option above already makes.
--
-- No Config.Features flag gates this pair, unlike every other ox_target
-- option in this resource (LeashMechanics above, VehicleEntryExit in
-- client/vehicle.lua, etc.): certify/revoke IS the access-control system
-- itself (SPEC.md hard requirement 2), not a togglable *feature area* sitting
-- behind that system the way Phase 1+'s other leaf features are framed in
-- §3's acceptance criteria ("every leaf feature... has a corresponding
-- Config.Features.X"). config.lua has no Certifications/CertifyHandler
-- entry in Config.Features, and the existing /k9certify, /k9decertify,
-- /k9decertifyoffline commands are likewise registered unconditionally —
-- this follows that same, already-established convention rather than
-- inventing a new toggle for it.
exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:certifyHandler',
        icon = 'fas fa-id-badge',
        label = 'Certify K9 Handler',
        distance = 2.5,
        canInteract = function(entity, distance, coords, name)
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- self-cert stays command-only (/k9certify [own id]), matches the leash option's self-exclusion above

            -- SPEC.md §4.2 condition 5: grant requires the TARGET's live
            -- ped model to be a configured K9 model. Cheap client-side
            -- plausibility check only — the server independently
            -- re-verifies via GetEntityModel(GetPlayerPed(targetServerId))
            -- regardless, see GrantCertification.
            return IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            TriggerServerEvent('qbx_k9unit:server:certifyHandler', GetPlayerServerId(targetPlayer))
        end,
    },
    {
        name = 'qbx_k9unit:revokeHandler',
        icon = 'fas fa-id-badge',
        label = 'Revoke K9 Certification',
        distance = 2.5,
        canInteract = function(entity, distance, coords, name)
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- self-decert stays command-only, matches certify above

            -- SPEC.md §4.2.5: the model check applies to GRANT only, not
            -- revoke (revoking must remain possible even if the target has
            -- already left K9 form) — but this predicate still reuses
            -- IsEntityModelK9 as the display-only plausibility gate rather
            -- than showing this option on every nearby player regardless
            -- of appearance, per this block's header note above (no new
            -- eligibility-check callback added this pass). A handler who
            -- has already left K9 form and needs their cert pulled remains
            -- reachable via /k9decertify [id] (or /k9decertifyoffline if
            -- they've since disconnected), neither of which has any model
            -- restriction at all — this ox_target option is a convenience
            -- entry point, not the only way to revoke.
            return IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            TriggerServerEvent('qbx_k9unit:server:revokeHandler', GetPlayerServerId(targetPlayer))
        end,
    },
})

-- NOTE on AgilityBasicJump (Config.Features.AgilityBasicJump): SPEC.md
-- §6.1 describes this as "native jump/crouch only, no fence-vault logic
-- yet" — i.e. Phase 1 doesn't add any custom jump/crouch code at all, the
-- flag exists so Phase 3's AgilityAdvanced has something to sit alongside
-- later. No stub function is needed here for it; if a future pass wants
-- to gate jump input itself behind this flag (e.g. disable jump entirely
-- when false), that's a deliberate addition, not implied by Phase 1.
