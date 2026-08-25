--[[
    qbx_k9unit/client/agility.lua

    EXTRACTED FROM client/movement.lua (this pass): the ADVANCED AGILITY
    block below (Config.Features.AgilityAdvanced's fence/window vault
    approximation) used to live at the bottom of client/movement.lua. It
    was pulled out into its own file because, unlike every other concern
    that file owns (camera toggle, Sit self-emote, the two-player leash
    mechanic, the shared K9 move-rate composer, AgilityBasicJump's
    suppression thread, door interaction), this block:
      - shares NO local state with anything else in client/movement.lua
        (confirmed by reading the whole file before moving this — no local
        variable/function defined here is read outside this block, and
        nothing here reads a local defined outside it either);
      - has nothing else in this resource depending on it at all (confirmed
        by grep across the whole tree for AgilityAdvanced/TryVault/
        DetectVaultableObstacleHeight/qbx_k9unit:vault before moving this —
        the only other hits are comments/spec docs, not code);
      - is entirely self-contained top-to-bottom: its own config validation
        assert, its own tuning constants, its own shape-test sweep helper,
        its own command/keybind registration, all gated behind the same
        single `if Config.Features.AgilityAdvanced then` block.
    Everything else in client/movement.lua either shares state across
    sections (the leash pull-back thread and the door-interaction/vault
    canInteract checks all consult IsInK9Vehicle()/CanShowK9UI() the same
    way, and the move-rate composer is read by three OTHER files) or is
    woven into that file's own always-on threads (the camera/AgilityBasicJump
    onResourceStop handlers) — none of that is true here, which is why this
    one block was judged to genuinely stand alone while the rest of
    client/movement.lua was not split further. client/movement.lua's own
    header carries the same note for anyone arriving from that file first.

    Only the "this file"/"above"/"below" self-references inside the block's
    original comments were adjusted for accuracy in this new location (e.g.
    a comment that used to say "this file's own Config.DoorInteraction...
    assertion above" now says "client/movement.lua's own ... assertion",
    since that assertion lives in the other file now). No code, native call,
    constant, gating condition, or behavior was changed by this move.

    Depends on resource-globals defined elsewhere, all consumed via plain
    call (not a `type(fn) == 'function'` guard) because this resource's own
    fxmanifest.lua load-order convention already places client/main.lua
    before this file and CanShowK9UI()/IsOwnModelK9() are unconditionally
    defined there (unlike, say, IsInK9Vehicle() below, which IS guarded —
    see the inline comment at its one call site for why: client/vehicle.lua
    loading after this file in the manifest is the reason, not a change
    introduced by this extraction — the original code in client/movement.lua
    already guarded that exact same call the same way):
      - Config (config.lua, shared_scripts, loaded before every client
        script)
      - CanShowK9UI() (client/main.lua)
      - IsOwnModelK9() referenced only in this block's header commentary,
        not called by any code path here
      - IsInK9Vehicle() (client/vehicle.lua, soft/optional — guarded)
    Exposes no resource-global of its own: RegisterCommand/RegisterKeyMapping
    are this file's only two entry points, exactly as in the original
    location.
]]

-- ======================================================================
-- ADVANCED AGILITY -- fence/window vault approximation
-- (Config.Features.AgilityAdvanced). PHASE3_SPEC.md §12.5.5, §12.0 item 3
-- (DECIDED: capsule-sweep raycast, detectionMethod = 'raycast', as the
-- Phase 3 default -- unaffected by Revision 3's PvP scope reversal), §12.1
-- sub-phase 3a ("independent, start immediately -- pure client-local
-- own-body movement, does not touch target/combat logic at all"), §12.3's
-- file/module plan (originally assigned to client/movement.lua's row:
-- "Extends... AgilityAdvanced's vault trigger and multi-height
-- capsule-sweep detection" -- now this separate file, see this file's own
-- header above for why it was pulled out).
--
-- SCOPE NOTE, checked explicitly before writing this block: this feature
-- NEVER resolves, targets, or applies any effect to another ped/player --
-- it only reads world geometry (via a capsule shape-test sweep) and
-- repositions the K9's OWN ped. It is therefore entirely UNAFFECTED by
-- PHASE3_SPEC.md §12.0 item 8 (the still-open, coder-security-owned
-- client-relay/non-cooperating-target-client question), which only
-- concerns effects a K9 applies to a DIFFERENT entity (BiteAndHold /
-- NonLethalTakedown / PropDragging). Do not conflate this feature with
-- those three just because they share the same Phase 3 config table.
--
-- EVENT/CALLBACK CONTRACT: NONE. No TriggerServerEvent, no callback,
-- nothing server-authoritative touched anywhere in this block -- matches
-- PHASE3_SPEC.md §12.5.5's own "Event/callback contract: unchanged --
-- minimal, entirely client-local" framing exactly.
--
-- GATING CHOICE: gated on CanShowK9UI() (not just the cheap, local
-- IsOwnModelK9() check client/movement.lua's camera toggle/AgilityBasicJump
-- suppression use) -- this is a genuinely new, opt-in-by-default-off Phase 3
-- capability layered ON TOP of native locomotion, not baseline behavior
-- inherent to the ped model the way jump/crouch are. This matches every
-- other self-initiated GRANTED capability in client/movement.lua (K9Sit,
-- RequestLeashAttach), not the baseline-QoL camera/native-locomotion
-- carve-out client/main.lua's own OPEN QUESTION note documents.
-- ======================================================================
if Config.Features.AgilityAdvanced then
    local agilityCfg = Config.Combat.AgilityAdvanced

    -- Fail loudly, not silently, if a server sets detectionMethod to
    -- anything other than the one Phase 3 default actually implemented
    -- here. PHASE3_SPEC.md §12.2/§12.5.5 document 'taggedProp' as a
    -- theoretical per-server override SHAPE, but no such detection path
    -- is built in this codebase -- same "assert rather than silently
    -- no-op a field that looks load-bearing" posture client/movement.lua's
    -- own Config.DoorInteraction.nudgeRequiresUnlocked assertion uses.
    assert(agilityCfg.detectionMethod == 'raycast',
        ("qbx_k9unit: Config.Combat.AgilityAdvanced.detectionMethod = '%s' is not implemented -- " ..
         "only 'raycast' (the PHASE3_SPEC.md §12.0 item 3 Phase 3 default, a multi-height capsule " ..
         "sweep) is built in client/agility.lua. Set it back to 'raycast', or implement the " ..
         "'taggedProp' path with a reviewed code change before shipping this value."):format(tostring(agilityCfg.detectionMethod)))

    -- Capsule-sweep TUNING CONSTANTS -- deliberately plain local constants,
    -- NOT promoted into config.lua, because PHASE3_SPEC.md §12.5.5's own
    -- "Open questions" list names the exact height bands/capsule radius/
    -- forward distance as in-engine TUNING work still to be done against
    -- real map geometry, not a settled design choice -- promoting untested
    -- numbers into a server-owner-facing config table would imply a
    -- confidence this file doesn't have yet. Revisit alongside
    -- maxVaultHeight/vaultCooldownMs once an in-engine tuning pass happens.
    local SWEEP_FORWARD_DISTANCE = 1.0                  -- meters ahead of the K9 to sweep toward
    local SWEEP_CAPSULE_RADIUS = 0.25                   -- meters, capsule thickness
    local SWEEP_HEIGHT_BANDS = { 0.3, 0.6, 0.9, 1.2 }   -- meters above the K9's own feet, each swept independently (see DetectVaultableObstacleHeight below for why one sweep per band, not one sweep total)
    -- Shape-test intersect flag bit for "world/map geometry only" (not
    -- peds/vehicles/objects) -- CONFIDENCE: MEDIUM. This is the
    -- widely-used ecosystem convention for START_SHAPE_TEST_*'s flags
    -- argument (bit 1 = IntersectMap), but unlike StartShapeTestCapsule/
    -- GetShapeTestResult's own hash/signature (HIGH confidence, verified
    -- directly against raw.githubusercontent.com/citizenfx/natives per
    -- phase2_notes/phase3_combat_natives.md §5), the exact flag-bit
    -- MEANINGS were not independently re-verified against that same
    -- canonical source this session -- if the sweep reports hits against
    -- unexpected entity types (or misses static fences/walls) in testing,
    -- this is the first value to have native-api-assistant re-confirm.
    local SHAPE_TEST_FLAG_INTERSECT_MAP = 1

    -- Bug fix (this pass): the polling loop below used to have no upper
    -- bound at all -- if GET_SHAPE_TEST_RESULT ever kept returning 1
    -- ("still processing") forever for a given handle (a stuck/leaked
    -- handle, or any other engine-side edge case that never resolves),
    -- TryVault() would hang in that coroutine permanently, once per
    -- height band, since nothing else in this function can make progress
    -- until the `repeat` loop below exits. A real capsule sweep against
    -- static world geometry is expected to resolve within a frame or two
    -- (see the loop's own comment), so a generous-but-bounded cap catches
    -- only the genuinely-stuck case, not a normal-but-slightly-slow one.
    -- Treated as "no hit" for that band on timeout, the same silent
    -- fallback this function already uses for a band that legitimately
    -- reports no hit -- consistent with this file's "cooldown/no-obstacle
    -- branches are silent, not notification spam" posture elsewhere.
    local SHAPE_TEST_MAX_POLLS = 60

    --- Multi-height capsule sweep: fires one shape test per configured
    --- height band, forward from the K9's current position, and returns
    --- the TALLEST band that still reports a hit as this obstacle's
    --- approximate climbable height. A single capsule sweep only reports
    --- "hit or not" for the exact line it was cast along -- it doesn't by
    --- itself tell you how tall the thing it hit is -- so sweeping several
    --- level bands and taking the tallest one that still connects
    --- approximates "solid up to at least this height," which is the
    --- actual question `maxVaultHeight` needs answered (distinguishing a
    --- low curb from a full wall).
    ---
    --- CONFIDENCE: the underlying natives are HIGH confidence (see above).
    --- This specific multi-band-sweep ALGORITHM built on top of them is
    --- this file's own construction, not verified in-engine this session --
    --- exactly the "in-engine tuning... against real map geometry"
    --- PHASE3_SPEC.md §12.5.5 already lists as open, unresolved TUNING
    --- work, not a design fork. Treat the returned height as an
    --- approximation to be validated against real fences/windows in
    --- testing, not a precise measurement.
    ---
    --- NON-NEGOTIABLE (per this resource's fxmanifest.lua `lua54` +
    --- `use_experimental_fxv2_oal` combination): this call reads ONLY
    --- resultCode and hit from GetShapeTestResult below -- never
    --- endCoords/surfaceNormal, the vector returns reported broken by that
    --- combination on some builds. Do not add a read of either vector
    --- return here without re-verifying that known issue against the build
    --- in use FIRST -- see fxmanifest.lua's own comment on this exact call
    --- for the full warning to a future editor.
    --- @param ped number
    --- @return number obstacleHeight -- 0.0 if nothing detected in any band
    local function DetectVaultableObstacleHeight(ped)
        local pedCoords = GetEntityCoords(ped)
        local forward = GetEntityForwardVector(ped)
        local tallestHit = 0.0

        for _, height in ipairs(SWEEP_HEIGHT_BANDS) do
            -- Level sweep at THIS band's height -- start and end share the
            -- same Z, forward.z is deliberately never applied to either
            -- endpoint, so every band stays level regardless of the K9's
            -- current ground pitch/slope.
            local startX, startY, startZ = pedCoords.x, pedCoords.y, pedCoords.z + height
            local endX = startX + forward.x * SWEEP_FORWARD_DISTANCE
            local endY = startY + forward.y * SWEEP_FORWARD_DISTANCE

            local shapeTestHandle = StartShapeTestCapsule(
                startX, startY, startZ, endX, endY, startZ,
                SWEEP_CAPSULE_RADIUS, SHAPE_TEST_FLAG_INTERSECT_MAP, ped, 0
            )

            -- GET_SHAPE_TEST_RESULT's own documented contract (confirmed,
            -- phase2_notes/phase3_combat_natives.md §5): poll until it
            -- returns 0 (invalid handle) or 2 (complete) -- 1 means "still
            -- processing," NOT a single guaranteed-synchronous call. A
            -- capsule sweep this short against static world geometry
            -- typically resolves within the same or next frame, but this
            -- loop does not assume that -- it keeps polling (yielding a
            -- frame between attempts) until the handle itself reports done.
            local resultCode, hit
            local pollCount = 0
            repeat
                resultCode, hit = GetShapeTestResult(shapeTestHandle)
                if resultCode == 1 then
                    pollCount = pollCount + 1
                    Wait(0)
                end
            until resultCode ~= 1 or pollCount >= SHAPE_TEST_MAX_POLLS

            if resultCode == 2 and hit then
                tallestHit = height
            end
            -- resultCode == 1 here means SHAPE_TEST_MAX_POLLS was reached
            -- without the handle ever resolving -- treated identically to
            -- "no hit this band" (see SHAPE_TEST_MAX_POLLS's own comment
            -- above), not an error.
        end

        return tallestHit
    end

    local lastVaultAt = -math.huge -- GetGameTimer()-scale; never on cooldown for the very first attempt

    --- Shared implementation behind the vault keybind below. Re-checks
    --- access/cooldown/obstacle every call -- there is no separate
    --- "canInteract"-style predicate for a keybind the way ox_target
    --- options in client/movement.lua get one, so all of that lives
    --- directly here.
    local function TryVault()
        if not CanShowK9UI() then
            lib.notify({ title = locale('common.notify_title'), description = locale('common.no_k9_access'), type = 'error' })
            return
        end

        local now = GetGameTimer()
        if (now - lastVaultAt) < agilityCfg.vaultCooldownMs then
            return -- silent -- a cooldown-rejected keypress retry isn't worth a notification every time, mirrors client/movement.lua's AgilityBasicJump's own no-notification-spam posture
        end

        local ped = PlayerPedId()
        if IsPedInAnyVehicle(ped, false) or (IsInK9Vehicle and IsInK9Vehicle()) then
            return -- nothing to vault over while seated/tucked, same exclusion client/movement.lua's leash pull-back thread and door-interaction options already apply for this exact state
        end

        local obstacleHeight = DetectVaultableObstacleHeight(ped)
        if obstacleHeight <= 0.0 or obstacleHeight > agilityCfg.maxVaultHeight then
            return -- nothing vaultable detected in range, or it's taller than configured -- silent, same reasoning as the cooldown branch above
        end

        lastVaultAt = now

        -- Scripted arc over the detected obstacle. PHASE3_SPEC.md
        -- §12.5.5's own wording correction applies here: there is no
        -- dedicated ped "jump" TASK native (confirmed absent,
        -- phase2_notes/phase3_combat_natives.md §5) -- this arc is driven
        -- directly via SET_ENTITY_VELOCITY (confirmed real,
        -- 0x1C99BB7B6E96D16F, HIGH confidence), an upward+forward impulse
        -- scaled by the detected obstacle's height, not a task/input
        -- simulation layered on native jump.
        --
        -- CONFIDENCE on the arc feel itself (verticalSpeed/forwardSpeed
        -- formula below): LOW/UNTUNED -- this is a first-pass placeholder
        -- shape, not derived from any confirmed source, and is exactly the
        -- kind of "in-engine tuning against real map geometry" work
        -- PHASE3_SPEC.md §12.5.5 already flags as open. Revisit after an
        -- in-engine pass, same as the sweep tuning constants above.
        local forward = GetEntityForwardVector(ped)
        local verticalSpeed = 4.0 + obstacleHeight * 2.0 -- taller obstacle -> slightly higher arc
        local forwardSpeed = 3.5
        SetEntityVelocity(ped, forward.x * forwardSpeed, forward.y * forwardSpeed, verticalSpeed)
    end

    RegisterCommand('qbx_k9unit:vault', function()
        TryVault()
    end, false)

    RegisterKeyMapping('qbx_k9unit:vault', locale('agility.vault_keybind_label'), 'keyboard', 'X')
end
