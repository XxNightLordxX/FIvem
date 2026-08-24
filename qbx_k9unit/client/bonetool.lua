--[[
    qbx_k9unit/client/bonetool.lua

    Client half of the dev-only bone-index sweep tool — see
    server/bonetool.lua's header for the full access-model/purpose writeup
    (read that file first). Built directly against this resource's own
    prior research (phase2_notes/phase5_remaining_features_research.md §2/§3,
    read in full before writing this file): no documented bone NAME exists
    for an `a_c_*` quadruped skeleton anywhere this codebase's research could
    reach, but `AttachEntityToEntity` only ever needed a raw INDEX, and
    `GetWorldPositionOfEntityBone` (confirmed directly against
    citizenfx/natives by that research pass, ENTITY namespace, hash
    0x44A8FCB8ED227738 / alt 0x7C6339DF) is entity-type-agnostic and requires
    no name at all — so the right tool is a raw-index position sweep, not
    another documentation search.

    TWO MODES, BOTH DRIVEN BY THE SAME `currentBoneIndex`:
    1. PREVIEW (subcommands 'goto'/'next'/'prev', always active once any of
       these has been used at least once): every frame, draws a small debug
       marker at `GetWorldPositionOfEntityBone(PlayerPedId(), currentBoneIndex)`.
       This is a pure position QUERY — it never creates an object and never
       calls AttachEntityToEntity — exactly the "cheapest possible" sweep
       primitive the research pass identified, and the reason this tool
       needs no marker prop model at all for this half of the workflow. A
       human walks around their own K9-modelled ped, runs '/k9bonetool goto
       <n>' (or next/prev to step by one), and watches where the marker
       lands relative to their own ped for each raw index.
    2. TEST (subcommand 'test'): once a candidate index looks promising in
       PREVIEW mode, this does a REAL CreateObject + AttachEntityToEntity at
       that exact index (via client/propattachment.lua's shared
       AttachPropToOwnPed — see that file's own contract), so the human can
       confirm the actual attach call (rotation space, offset behavior,
       whether it clips during this resource's existing bark/pant scenario
       animations — see the research note on FetchMechanic's mouth-bone
       articulation risk) rather than trusting the position query alone.

    GRACEFUL DEGRADATION: `GetWorldPositionOfEntityBone`'s behavior for an
    out-of-range index was NOT independently confirmed this session (no live
    client available) — the research pass's own honest assessment is
    "expected to fail gracefully... based on the sibling native's documented
    -1-on-miss convention," not a confirmed fact for THIS native
    specifically. This file never asserts on the returned vector — an
    invalid index is expected, at worst, to draw a marker at some
    uninformative position (e.g. coincident with the ped's own root), which
    is itself useful sweep information ("nothing distinct lives at this
    index"), never a crash.

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `AttachPropToOwnPed`/`DetachAndDeleteProp`, both
      exposed by client/propattachment.lua — do not re-implement the
      CreateObject/RequestModel/AttachEntityToEntity sequence here. NO HARD
      LOAD-ORDER REQUIREMENT: both calls happen at RUNTIME, inside this
      file's own event handler / local functions, never at file-load time —
      same "global-function resolution is at call time, not load time"
      convention client/combat.lua's own header already established for its
      own soft cross-file dependencies. Placed after client/propattachment.lua
      in fxmanifest.lua purely for topical/reading-order grouping (both
      files serve the same PropAttachments/bone-index problem), not because
      either requires it.
    - THIS FILE exposes no resource-global functions of its own.
]]

-- Debug-marker draw constants — plain local constants, not config, since
-- this is purely a rendering choice for a dev-only tool, not a tunable
-- gameplay value. Small, bright red sphere-ish marker (native marker type 1,
-- a widely-used generic debug marker shape in the wider FiveM ecosystem) —
-- MEDIUM confidence on the specific type-1 shape rendering as expected
-- (not independently re-verified in this sandbox), but DrawMarker itself is
-- already an established native in this codebase (client/movement.lua's
-- AgilityAdvanced groundwork) and an out-of-range/unexpected marker type is
-- expected to be a harmless no-render, never a crash, per this native's own
-- long-standing ecosystem-wide convention.
local MARKER_TYPE = 1
local MARKER_SCALE = 0.15
local MARKER_COLOR = { r = 255, g = 40, b = 40, a = 200 }

-- This client's own state — all local-only, never read from another file.
local sweepActive = false
local currentBoneIndex = 0
local testEntity = nil

--- @param boneIndex number
--- @param maxIndex number
--- @return number clamped
local function ClampBoneIndex(boneIndex, maxIndex)
    if boneIndex < 0 then return 0 end
    if boneIndex > maxIndex then return maxIndex end
    return boneIndex
end

--- Sets the active preview index, starts the draw loop if not already
--- running, and gives the human immediate feedback on what index they're
--- now looking at.
--- @param boneIndex number
local function SetPreviewBoneIndex(boneIndex)
    currentBoneIndex = boneIndex
    sweepActive = true
    lib.notify({ title = 'K9 Unit — Bone Tool', description = ('Previewing bone index: %d'):format(boneIndex), type = 'inform' })
    print(('[qbx_k9unit] bonetool: previewing bone index %d'):format(boneIndex))
end

-- ======================================================================
-- REGISTRATION-TIME FEATURE GATE (coder-security, this pass) — the preview
-- draw thread below, the RegisterNetEvent handler, and the onResourceStop
-- cleanup hook are now all inside this single `if`, evaluated once at this
-- file's own load time. Config.lua is a shared_scripts file, loaded in full
-- before any client_scripts file runs, so Config.Features.BoneSweepDevTool
-- already holds its real value here — not a load-order gamble. Mirrors this
-- SAME file's own client/propattachment.lua sibling gate and this
-- resource's server/bonetool.lua precedent ('/k9bonetool' is only ever
-- RegisterCommand'd inside its own flag-checked onResourceStart): a
-- dev-only sweep tool left merely "gated inside the handler" would still
-- run a per-frame draw thread (once triggered) and a registered, reachable
-- event on every production client that never opted in — this makes it
-- genuinely inert instead, not merely hidden. The FEATURE GATE check
-- already inside the handler below is kept regardless, as defense-in-depth
-- (same "layered checks" posture as the SOURCE-ORIGIN GUARD immediately
-- below it).
-- ======================================================================
if Config.Features and Config.Features.BoneSweepDevTool == true then

--- PREVIEW draw loop — only does real work while `sweepActive` is true, and
--- backs off to a slow poll otherwise so this thread costs nothing for the
--- overwhelming majority of a session where the tool isn't in use (this
--- resource's own established "don't run a hot loop for an inactive
--- feature" convention, e.g. client/wellbeing.lua's own tick-gating).
CreateThread(function()
    while true do
        if sweepActive then
            local ped = PlayerPedId()
            if DoesEntityExist(ped) and not IsEntityDead(ped) then
                local pos = GetWorldPositionOfEntityBone(ped, currentBoneIndex)
                DrawMarker(
                    MARKER_TYPE, pos.x, pos.y, pos.z,
                    0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    MARKER_SCALE, MARKER_SCALE, MARKER_SCALE,
                    MARKER_COLOR.r, MARKER_COLOR.g, MARKER_COLOR.b, MARKER_COLOR.a,
                    false, false, 2, false, nil, nil, false
                )
            end
            Wait(0) -- DrawMarker must be reasserted every frame, same discipline as every other per-frame native call already in this resource
        else
            Wait(500)
        end
    end
end)

--- TEST mode: a real CreateObject + AttachEntityToEntity at
--- `currentBoneIndex`, via the shared mechanic client/propattachment.lua
--- exposes. Replaces any previous test object first.
local function RunAttachTest()
    DetachAndDeleteProp(testEntity)
    testEntity = nil

    local cfg = Config.BoneSweepTool
    local obj = AttachPropToOwnPed(
        cfg.TestPropModel, currentBoneIndex,
        cfg.TestOffsetX, cfg.TestOffsetY, cfg.TestOffsetZ,
        0.0, 0.0, 0.0,
        false, -- isNetworked: local-only diagnostic aid, see this file's header
        nil
    )

    if not obj then
        lib.notify({ title = 'K9 Unit — Bone Tool', description = 'Test prop failed to load.', type = 'error' })
        return
    end

    testEntity = obj
    lib.notify({ title = 'K9 Unit — Bone Tool', description = ('Test-attached at bone index %d'):format(currentBoneIndex), type = 'inform' })
end

--- Server-issued instruction — see server/bonetool.lua's own EVENT
--- CONTRACT for the full subcommand list.
--- @param subcommand string
--- @param index number?
RegisterNetEvent('qbx_k9unit:client:boneToolCommand', function(subcommand, index)
    -- SOURCE-ORIGIN GUARD (coder-security precedent — see
    -- client/combat.lua's "SOURCE-ORIGIN GUARD" header block and
    -- phase2_notes/client_event_trust_boundary.md for the full writeup, not
    -- re-derived here). Confidence: MEDIUM-HIGH, the official documented
    -- pattern, not independently verified in-engine this pass.
    if source ~= 65535 then return end

    -- FEATURE GATE — this handler must never fire real effects while the
    -- flag is off, even though server/bonetool.lua only ever sends this
    -- event from behind its own flag+ACE gate; defense in depth, matching
    -- every other gated handler's own per-handler convention in this
    -- resource.
    if not (Config.Features and Config.Features.BoneSweepDevTool == true) then return end

    local maxIndex = (Config.BoneSweepTool and Config.BoneSweepTool.MaxBoneIndex) or currentBoneIndex

    if subcommand == 'goto' then
        if type(index) ~= 'number' then return end
        SetPreviewBoneIndex(ClampBoneIndex(math.floor(index), maxIndex))
    elseif subcommand == 'next' then
        SetPreviewBoneIndex(ClampBoneIndex(currentBoneIndex + 1, maxIndex))
    elseif subcommand == 'prev' then
        SetPreviewBoneIndex(ClampBoneIndex(currentBoneIndex - 1, maxIndex))
    elseif subcommand == 'test' then
        RunAttachTest()
    elseif subcommand == 'stop' then
        sweepActive = false
        DetachAndDeleteProp(testEntity)
        testEntity = nil
    end
end)

-- Resource-restart safety net — same class of fix as
-- client/propattachment.lua's/client/kennel.lua's own onResourceStop
-- handlers. Doubly important here since this is a dev-only tool expected to
-- be used, forgotten about, and left running mid-session.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    sweepActive = false
    DetachAndDeleteProp(testEntity)
    testEntity = nil
end)

end -- if Config.Features.BoneSweepDevTool -- REGISTRATION-TIME FEATURE GATE, see this block's own opening comment
