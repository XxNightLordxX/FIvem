--[[
    qbx_k9unit/client/propattachment.lua

    Client half of Config.Features.PropAttachments — see
    server/propattachment.lua's header for the full event contract, the
    "why this never accepts a client-claimed target ped" trust-boundary
    reasoning, and the bone-index research-blocker/reframe note. Read that
    file before changing anything here.

    ======================================================================
    FILE-TO-FILE CONTRACT — SHARED SURFACE FOR THE CONCURRENTLY-BUILT
    FetchMechanic FEATURE (per this pass's own task brief: "write the sweep
    tool so it serves both [PropAttachments and FetchMechanic]" — the same
    reasoning extends to the plain attach/detach mechanics below, which are
    generic over "attach some prop to my own ped at some bone index," not
    specific to a vest):
        AttachPropToOwnPed(modelName: string, boneIndex: number,
            offsetX: number, offsetY: number, offsetZ: number,
            rotX: number, rotY: number, rotZ: number,
            isNetworked: boolean, timeoutMs: number?) -> entity: number?
      Loads `modelName` (falls back to nothing — caller decides its own
      fallback model, same "one model per call" contract client/kennel.lua's
      LoadModelWithTimeout already established), creates an object at the
      caller's own current PlayerPedId() position, attaches it via
      AttachEntityToEntity at `boneIndex` with the given offset/rotation, and
      returns the resulting entity handle — or nil on ANY failure (bad model
      name, model never loads in time, CreateObject fails) — NEVER errors.
      `isNetworked` controls CreateObject's own isNetwork argument: pass
      `true` for anything meant to be visible to OTHER clients (this file's
      own vest use), `false` for a purely local visual aid with no other
      consumer (client/bonetool.lua's marker prop). The caller is entirely
      responsible for whatever server-side confirm/registration step its own
      feature needs on top of this — this function only ever creates a LOCAL
      handle, it never talks to the network layer beyond CreateObject's own
      isNetworked flag.
        DetachAndDeleteProp(entity: number?) -> nil
      Safe teardown: DetachEntity then DeleteEntity, guarded by
      DoesEntityExist so calling this with an already-gone or nil entity is
      always a harmless no-op. Every removal path in this file (manual
      toggle-off receipt, own-death auto-detach, onResourceStop) funnels
      through this one function so there is exactly one place that ever
      calls DetachEntity/DeleteEntity for a prop this file created.
    Neither function is gated on Config.Features.PropAttachments — they are
    generic mechanics, not the feature itself; the FEATURE gate lives at
    each of THIS FILE's own call sites below (RequestToggleK9PropAttachment,
    the attachK9Prop/removeK9PropAttachment event handlers), exactly like
    the "gate at the point of activation, not the primitive" split
    server/entities.lua's ResolveNetworkEntity already established for the
    server side.
    ======================================================================

    - THIS FILE calls client/main.lua's CanShowK9UI()/DenyK9UIAccess() and
      IsOwnModelK9(), same as every other gated client action in this
      resource.
]]

-- Milliseconds to wait for RequestModel to actually finish loading before
-- giving up — same value/reasoning as client/kennel.lua's own
-- REQUEST_MODEL_TIMEOUT_MS (a single small prop, generous ceiling).
-- Duplicated rather than shared per this resource's established "tiny
-- constant/helper, private per file" convention (see client/kennel.lua's
-- own NotifyPlayer-equivalent duplication note in server/kennel.lua).
local REQUEST_MODEL_TIMEOUT_MS = 5000

--- Shared attach/detach mechanic — see this file's header FILE-TO-FILE
--- CONTRACT block for the full parameter/return contract. NEVER errors:
--- every failure path returns nil instead.
--- @param modelName string
--- @param boneIndex number
--- @param offsetX number
--- @param offsetY number
--- @param offsetZ number
--- @param rotX number
--- @param rotY number
--- @param rotZ number
--- @param isNetworked boolean
--- @param timeoutMs number?
--- @return number? entity
function AttachPropToOwnPed(modelName, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, isNetworked, timeoutMs)
    if type(modelName) ~= 'string' or modelName == '' then return nil end

    local modelHash = GetHashKey(modelName)
    if not IsModelValid(modelHash) then
        return nil -- not even a recognized model hash on this client's installed game data
    end

    RequestModel(modelHash)
    local waited = 0
    local timeout = timeoutMs or REQUEST_MODEL_TIMEOUT_MS
    while not HasModelLoaded(modelHash) and waited < timeout do
        Wait(50)
        waited = waited + 50
    end

    if not HasModelLoaded(modelHash) then
        return nil
    end

    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped)
    local obj = CreateObject(modelHash, pedCoords.x, pedCoords.y, pedCoords.z, isNetworked == true, true, false)
    SetModelAsNoLongerNeeded(modelHash)

    if not DoesEntityExist(obj) then
        return nil
    end

    -- Same argument shape as client/combat.lua's PropDragging attach call
    -- (AttachEntityToEntity(targetPed, PlayerPedId(), 0, 0.0, -0.6, 0.0,
    -- 0.0, 0.0, 0.0, true, false, false, false, 2, true)) — reused
    -- deliberately rather than inventing a new flag combination, so this
    -- call inherits that call site's own confidence grading rather than a
    -- fresh, independently-unverified one. Collision (arg 11) is left
    -- false here too: a cosmetic/diagnostic prop riding along on a ped
    -- should never physically interact with the world.
    AttachEntityToEntity(obj, ped, boneIndex, offsetX, offsetY, offsetZ, rotX, rotY, rotZ, true, false, false, false, 2, true)

    return obj
end

--- Safe teardown — see this file's header FILE-TO-FILE CONTRACT block.
--- @param entity number?
function DetachAndDeleteProp(entity)
    if not entity or not DoesEntityExist(entity) then return end
    DetachEntity(entity, true, false)
    DeleteEntity(entity)
end

-- This client's own currently-attached vest entity, if any (nil otherwise).
-- Local-only, never read from another file. This is a CLIENT-SIDE MIRROR of
-- server/propattachment.lua's authoritative PropAttachmentState entry, not
-- an independent source of truth — see client/kennel.lua's own
-- myKennelNetId comment for the identical reasoning applied here.
local myVestEntity = nil

-- DEFENSE-IN-DEPTH MODEL ALLOWLIST (coder-security pass) — same role as
-- client/kennel.lua's own KennelPropModelHashes on its removeKennel handler:
-- even with the SOURCE-ORIGIN GUARD below, a DeleteEntity driven entirely by
-- a caller-supplied netId should never trust that the resolved entity is
-- actually one of THIS feature's own props. Built LAZILY (not at file-load
-- time like KennelPropModelHashes) because Config.PropAttachments is only
-- guaranteed to exist once the feature is genuinely enabled and
-- server/propattachment.lua's own onResourceStart config-safety guard has
-- already validated its shape — reading cfg.propModel/fallbackPropModel at
-- file-load time here would error on a server that ships this file with the
-- feature left off (its shipped default), since Config.PropAttachments
-- itself does not exist in that state.
--- @return table<number, boolean>? modelHashes nil if Config.PropAttachments isn't a valid table yet
local PropAttachmentModelHashes = nil
local function GetPropAttachmentModelHashes()
    if PropAttachmentModelHashes then return PropAttachmentModelHashes end

    local cfg = Config.PropAttachments
    if type(cfg) ~= 'table' then return nil end

    local hashes = {}
    if type(cfg.propModel) == 'string' and cfg.propModel ~= '' then
        hashes[GetHashKey(cfg.propModel)] = true
    end
    if type(cfg.fallbackPropModel) == 'string' and cfg.fallbackPropModel ~= '' then
        hashes[GetHashKey(cfg.fallbackPropModel)] = true
    end

    if next(hashes) == nil then return nil end -- malformed config -- never allowlist an empty set (that would vacuously reject everything anyway, but be explicit)
    PropAttachmentModelHashes = hashes
    return PropAttachmentModelHashes
end

--- Requests the toggle. Exposed globally rather than kept as a
--- command-local closure, mirroring client/kennel.lua's
--- RequestDeployKennel() — so a future radial entry can call this directly
--- without this file needing to change.
function RequestToggleK9PropAttachment()
    if not Config.Features.PropAttachments then return end

    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    -- No client-side "already have one" short-circuit before the server
    -- round trip the way client/kennel.lua has one — unlike a kennel
    -- placement (a genuinely new action every time), a toggle is a single
    -- request whose MEANING (add vs remove) is decided server-side by
    -- whether PropAttachmentState already has an entry; this file doesn't
    -- need to predict that to know whether to send the request.
    TriggerServerEvent('qbx_k9unit:server:requestToggleK9PropAttachment')
end

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE (coder-security, this pass) — the command
-- below, all three RegisterNetEvent handlers, the own-death auto-detach
-- thread, and the onResourceStop hook are now all inside this single `if`,
-- evaluated once at this file's own load time (config.lua is a
-- shared_scripts file, loaded in full before any client_scripts file runs,
-- so Config.Features.PropAttachments already holds its real value here —
-- not a load-order gamble). AttachPropToOwnPed/DetachAndDeleteProp/
-- GetPropAttachmentModelHashes/RequestToggleK9PropAttachment above stay
-- OUTSIDE this gate on purpose — see this file's own FILE-TO-FILE CONTRACT
-- header ("Neither function is gated on Config.Features.PropAttachments")
-- for AttachPropToOwnPed/DetachAndDeleteProp specifically (client/bonetool.lua
-- calls both regardless of THIS flag, gated instead on its own
-- BoneSweepDevTool flag); RequestToggleK9PropAttachment already gates
-- itself internally and must stay reachable-but-inert for a future radial
-- entry per its own doc comment, same as client/kennel.lua's
-- RequestDeployKennel.
-- WHY THIS MATTERS BEYOND THE EXISTING PER-HANDLER `if not
-- Config.Features.PropAttachments then return end` CHECKS ALREADY INSIDE
-- each handler below (kept, deliberately, as defense-in-depth, same
-- "layered checks" posture as the SOURCE-ORIGIN GUARD remaining even though
-- the feature gate also exists): a per-handler check still means
-- '/k9propattach' and all three 'qbx_k9unit:client:*' events ARE registered
-- and reachable on a client with the feature left off. Wrapping the
-- registration itself means a server that has never opted into
-- PropAttachments ships clients where this command/these events do not
-- exist AT ALL, and the death-poll thread never starts — genuinely inert,
-- not merely hidden behind an early return, matching this resource's own
-- server/bonetool.lua precedent (its '/k9bonetool' command is only ever
-- RegisterCommand'd inside its own flag-checked onResourceStart).
-- ======================================================================
if Config.Features.PropAttachments then

RegisterCommand('k9propattach', function()
    RequestToggleK9PropAttachment()
end, false)

--- Server-issued instruction: create+attach the configured prop to your OWN
--- ped, then report its netId back (or cancel if it never loads).
RegisterNetEvent('qbx_k9unit:client:attachK9Prop', function()
    -- SOURCE-ORIGIN GUARD (coder-security precedent — see
    -- client/combat.lua's "SOURCE-ORIGIN GUARD" header block and
    -- phase2_notes/client_event_trust_boundary.md for the full writeup, not
    -- re-derived here). 65535 is FiveM's documented client-side sentinel
    -- for "this event genuinely came from the server" (citizenfx/fivem-docs,
    -- "Secure your events"). Confidence: MEDIUM-HIGH, the official
    -- documented pattern, not independently verified in-engine this pass.
    if source ~= 65535 then return end

    -- FEATURE GATE — this handler must never fire real effects while the
    -- flag is off, matching every other gated handler's own per-handler
    -- gating convention in this resource (client/kennel.lua's
    -- deployKennelAt/removeKennel are the closest precedent).
    if not Config.Features.PropAttachments then return end

    local cfg = Config.PropAttachments
    local obj = AttachPropToOwnPed(
        cfg.propModel, cfg.boneIndex,
        cfg.offsetX, cfg.offsetY, cfg.offsetZ,
        cfg.rotX, cfg.rotY, cfg.rotZ,
        true, -- isNetworked: other players must see this
        nil
    )

    local usedFallback = false
    if not obj then
        usedFallback = true
        obj = AttachPropToOwnPed(
            cfg.fallbackPropModel, cfg.boneIndex,
            cfg.offsetX, cfg.offsetY, cfg.offsetZ,
            cfg.rotX, cfg.rotY, cfg.rotZ,
            true, nil
        )
    end

    if not obj then
        lib.notify({ title = locale('common.notify_title'), description = locale('propattachment.vest_prop_load_failed'), type = 'error' })
        TriggerServerEvent('qbx_k9unit:server:cancelPropAttachRequest')
        return
    end

    if usedFallback then
        -- Low-key server-console breadcrumb, not a player-facing error —
        -- same posture/wording convention as client/kennel.lua's own
        -- fallback breadcrumb.
        print(('[qbx_k9unit] PropAttachments: propModel "%s" failed to load, used fallbackPropModel "%s" instead — see config.lua\'s Config.PropAttachments comment.'):format(cfg.propModel, cfg.fallbackPropModel))
    end

    myVestEntity = obj
    local netId = NetworkGetNetworkIdFromEntity(obj)
    TriggerServerEvent('qbx_k9unit:server:confirmPropAttached', netId)
end)

--- Server rejected this client's own just-created attachment (failed the
--- server's model/position defense-in-depth checks) — undo it locally.
RegisterNetEvent('qbx_k9unit:client:rejectK9PropAttach', function()
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see attachK9Prop's own comment above
    if not Config.Features.PropAttachments then return end

    DetachAndDeleteProp(myVestEntity)
    myVestEntity = nil
end)

--- Cleanup backstop broadcast from server/propattachment.lua — see that
--- file's RemovePropAttachmentForCitizenid CLEANUP CONFIDENCE NOTE for why
--- this exists alongside the server's own direct DeleteEntity attempt. Safe
--- no-op for any client that doesn't have this netId streamed in.
--- @param netId number
RegisterNetEvent('qbx_k9unit:client:removeK9PropAttachment', function(netId)
    if source ~= 65535 then return end -- SOURCE-ORIGIN GUARD — see attachK9Prop's own comment above
    if not Config.Features.PropAttachments then return end
    if type(netId) ~= 'number' then return end

    -- REFACTOR_ROADMAP.md near-term item 2 migration: this was previously a
    -- hand-rolled "NetworkDoesEntityExistWithNetworkId -> NetworkGetEntityFromNetworkId
    -- -> DoesEntityExist" sequence, the exact pattern this resource already
    -- centralised into client/main.lua's ResolveNetworkEntity (a NEW,
    -- unmigrated 7th copy caught by a refactor audit — see that function's
    -- own doc comment for the 6 prior copies it already replaced). Do not
    -- re-introduce a hand-rolled copy of this sequence anywhere in this file.
    local entity = ResolveNetworkEntity(netId)
    if not entity then return end

    -- DEFENSE-IN-DEPTH MODEL CHECK — mirrors client/kennel.lua's own
    -- removeKennel handler verbatim: server/propattachment.lua's own
    -- dispatch site only ever broadcasts a genuine vest's netId, but nothing
    -- upstream of this line re-derives that fact here. Restricting the
    -- delete to an entity whose CURRENT model actually matches one of the
    -- two configured prop models turns "arbitrary entity deletion" into, at
    -- worst, "delete some other player's legitimately attached vest prop" —
    -- should the origin guard above ever be defeated by something this pass
    -- could not evaluate (see that guard's own confidence note). A nil
    -- return from GetPropAttachmentModelHashes() (malformed/missing config)
    -- fails closed — never deletes anything.
    local modelHashes = GetPropAttachmentModelHashes()
    if not modelHashes or not modelHashes[GetEntityModel(entity)] then return end

    if myVestEntity == entity then
        myVestEntity = nil
    end

    DetachAndDeleteProp(entity)
end)

-- OWN-DEATH AUTO-DETACH (task requirement: an attached prop must be cleaned
-- up on K9 death). Lightweight poll, only running at all while this client
-- actually has a vest attached — mirrors client/vision.lua's/
-- client/screenfx.lua's own existing IsEntityDead(PlayerPedId()) polling
-- pattern for the same class of "is my own ped currently dead" check.
-- Self-reported to the server (see server/propattachment.lua's header event
-- 4 for the trust-category reasoning) rather than assumed handled purely
-- client-side, so the SERVER's own PropAttachmentState (and therefore the
-- broadcast backstop to every other client) is cleared too, not just this
-- client's local view.
CreateThread(function()
    while true do
        Wait(1000)
        if myVestEntity and DoesEntityExist(PlayerPedId()) and IsEntityDead(PlayerPedId()) then
            DetachAndDeleteProp(myVestEntity)
            myVestEntity = nil
            TriggerServerEvent('qbx_k9unit:server:reportOwnK9PropAttachDeath')
        end
    end
end)

-- Resource-restart safety net (same class of fix as client/kennel.lua's own
-- onResourceStop handler, flagged there as a "ship-blocking QA finding" for
-- a different piece of entity state): if THIS client attached a vest and
-- the resource stops while it's still connected, delete it locally rather
-- than leaving a frozen, ownerless object behind. Covers the common "still
-- connected at resource restart" case; server/propattachment.lua's own
-- onResourceStop loop covers attachments whose creating client already
-- disconnected earlier in the session.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if not myVestEntity then return end

    DetachAndDeleteProp(myVestEntity)
    myVestEntity = nil
end)

end -- if Config.Features.PropAttachments -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
