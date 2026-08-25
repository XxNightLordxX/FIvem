--[[
    qbx_k9unit/client/training.lua

    Client half of Training Mode -- FEATURE_IDEAS.md Part A Tier B §6. See
    server/training.lua's own header for the full contract, the XP
    decision, and the "unmistakably distinct from live duty" reasoning;
    this file is deliberately thin on top of it -- every real gate (access,
    zone, cooldown, the forced end of any real engagement) is
    server-authoritative, exactly like every other mechanic in this
    resource. This file's own job is presentation only: two commands that
    round-trip to the server, and a persistent, impossible-to-miss
    on-screen indicator so a handler can never lose track of whether they
    are training or on live duty.

    ======================================================================
    EVENT/CALLBACK CONTRACT (server side lives in server/training.lua):

    Server events (client->server):
    - 'qbx_k9unit:server:setTrainingMode' (desiredOn: boolean) [THIS FILE]

    Client events (server->client):
    - 'qbx_k9unit:client:trainingModeChanged' (isOn: boolean) [THIS FILE] --
      the ONLY thing that ever flips this file's own `trainingModeActive`
      local. Never set optimistically from a command handler -- the
      persistent banner below reflects SERVER-CONFIRMED state only, per
      server/training.lua's header point 4.

    Callbacks (ox_lib lib.callback, client->server):
    - 'qbx_k9unit:server:trainingSearch' () -> { ok, reason?, contrabandFound?, reps? } [THIS FILE awaits]
    - 'qbx_k9unit:server:trainingBiteHold' () -> { ok, reason?, reps? } [THIS FILE awaits]

    Commands:
    - '/k9training <on|off>' -- requests the corresponding transition.
    - '/k9trainsearch' -- practice search drill (no-op locally, with a
      usage notice, if `trainingModeActive` is currently false -- a UX
      convenience only; server/training.lua's own
      CheckTrainingActionEligibility independently re-verifies everything
      regardless of what this local flag currently believes).
    - '/k9trainbite' -- practice bite-and-hold drill, identical shape.
    ======================================================================

    NOT AN ox_target INTERACTION, DELIBERATELY, THIS PASS: every other
    mechanic in this resource pairs a chat command with an ox_target option
    on some in-world entity (a player, a vehicle, a door). Training's own
    two drills have no real target to attach an ox_target option TO --
    server/training.lua's own header point 1 states plainly that neither
    callback takes a target argument at all, precisely so nothing here can
    ever be pointed at something real. Spawning a purely cosmetic, local,
    non-networked "practice dummy" entity to hang an ox_target option off
    of was considered and deliberately NOT built this pass: it would need a
    specific ped/prop model name, and this resource's own established
    confidence discipline (see e.g. client/kennel.lua's
    "PROP MODEL CONFIDENCE" section, phase2_notes' repeated "do not
    fabricate a scenario/model name" standard) does not permit asserting
    one is real without verification against a live client, which this
    session had no way to perform. Chat commands need no such asset and
    deliver the same practice-flow value (request -> wait -> scripted
    result -> feedback) without it. Upgrading to a physical target dummy +
    ox_target proximity interaction is a natural follow-up once a specific
    model is confirmed for a given server's own asset set.
]]

-- FEATURE GATE, mirroring server/training.lua's own first executable line.
-- Without this, all three commands registered below -- and the permanent
-- banner-draw thread -- came up even with the feature off, and
-- `/k9training on` fired an event at a server that had registered no
-- handler for it: total silence, no error, no notify. A registered command
-- that always refuses is worse than an absent one, because it advertises a
-- feature the server does not have. Every other new feature file in this
-- resource already gates this way at file top level (client/scenttrail.lua,
-- client/tablet.lua, server/leaderboard.lua); this file was the exception.
if not Config.Features.TrainingMode then return end

-- SERVER-CONFIRMED ONLY -- see this file's header EVENT/CALLBACK CONTRACT.
-- Never set directly by a command handler in this file.
local trainingModeActive = false

-- Session-only, for the banner's own display purposes ONLY -- the
-- authoritative rep count is server/training.lua's TrainingReps, echoed
-- back to us in every drill's own `reps` field; this local mirror exists
-- only so the persistent banner can show a live number without an extra
-- round trip. Never read by anything else, never persisted.
local lastKnownReps = 0

RegisterNetEvent('qbx_k9unit:client:trainingModeChanged', function(isOn)
    -- SOURCE-ORIGIN GUARD -- see client/combat.lua's own "SOURCE-ORIGIN
    -- GUARD" header block for the full writeup (not re-derived here); 65535
    -- is FiveM's documented sentinel for "this event genuinely came from
    -- the server". Cosmetic-only payoff if forged (a fake banner toggle),
    -- applied for resource-wide consistency with every other
    -- `qbx_k9unit:client:*` handler in this resource.
    if source ~= 65535 then return end

    trainingModeActive = isOn == true
    if not trainingModeActive then
        lastKnownReps = 0
    end
end)

RegisterCommand('k9training', function(_source, args)
    local mode = args[1]
    if mode == 'on' then
        TriggerServerEvent('qbx_k9unit:server:setTrainingMode', true)
    elseif mode == 'off' then
        TriggerServerEvent('qbx_k9unit:server:setTrainingMode', false)
    else
        lib.notify({ title = locale('common.notify_title'), description = locale('training.usage'), type = 'error' })
    end
end, false)

--- Shared shell for both practice drills below -- pacing via
--- lib.progressBar (the same primitive/UX shape client/search.lua's own
--- PerformSearch already establishes for this resource), then an awaited
--- server round trip, pcall-wrapped throughout so a thrown
--- lib.callback.await (timeout/rejection -- THROWS, never returns nil,
--- per this resource's own established caveat, see client/search.lua's
--- identical disclosure) can never surface as an uncaught error.
--- @param eventName string
--- `progressLabel` is an ALREADY-RESOLVED string (the caller's own
--- `locale('training.xxx')` call), never a key name for this function to
--- resolve itself -- every `locale(...)` call in this file uses a literal
--- string argument, at its own call site, matching this codebase's
--- established convention (e.g. client/search.lua's own
--- `locale('search.progress_vehicle_label')` literal) precisely so a
--- locale cross-reference tool scanning for literal `locale('...')` calls
--- can find every key this file actually uses -- a key name threaded
--- through as a plain string PARAMETER would be invisible to that kind of
--- scan.
--- @param progressLabel string
--- @param onSuccess fun(result: table)
local function RunTrainingDrill(eventName, progressLabel, onSuccess)
    if not trainingModeActive then
        lib.notify({ title = locale('common.notify_title'), description = locale('training.not_training'), type = 'error' })
        return
    end

    local completed = lib.progressBar({
        duration = 4000,
        label = progressLabel,
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, combat = true },
    })
    if not completed then
        return -- player cancelled/moved away; no server call made at all, mirrors PerformSearch's identical early-out
    end

    local ok = pcall(function()
        local result = lib.callback.await(eventName, false)

        if not result or not result.ok then
            local reason = result and result.reason
            -- 'on_cooldown' is a silent, low-key no-op -- matches this
            -- resource's established cooldown-UX convention
            -- (client/search.lua's own PerformSearch treats 'on_cooldown'
            -- identically). Every OTHER reason ('not_training' / 'too_far'
            -- / 'no_access' / an unrecognized/missing reason) gets a plain
            -- notify: server/training.lua's own
            -- CheckTrainingActionEligibility ALSO fires
            -- trainingModeChanged(false) for the first two of those when it
            -- detects the drift server-side -- this notify is purely the
            -- player-facing explanation, not what turns the banner off (the
            -- event above is the only thing that does that).
            if reason ~= 'on_cooldown' then
                lib.notify({ title = locale('common.notify_title'), description = locale('training.action_denied'), type = 'error' })
            end
            return
        end

        if type(result.reps) == 'number' then
            lastKnownReps = result.reps
        end

        onSuccess(result)
    end)

    if not ok then
        lib.notify({ title = locale('common.notify_title'), description = locale('training.action_denied'), type = 'error' })
    end
end

RegisterCommand('k9trainsearch', function()
    RunTrainingDrill('qbx_k9unit:server:trainingSearch', locale('training.search_progress_label'), function(result)
        lib.notify({
            title = locale('common.notify_title'),
            description = result.contrabandFound and locale('training.search_result_found') or locale('training.search_result_clean'),
            type = result.contrabandFound and 'success' or 'info',
        })
    end)
end, false)

RegisterCommand('k9trainbite', function()
    RunTrainingDrill('qbx_k9unit:server:trainingBiteHold', locale('training.bite_hold_progress_label'), function()
        lib.notify({ title = locale('common.notify_title'), description = locale('training.bite_hold_complete'), type = 'success' })
    end)
end, false)

-- ======================================================================
-- PERSISTENT ON-SCREEN BANNER -- server/training.lua's header point 4
-- ("VISIBLE STATE"). Deliberately NOT routed through client/hud.lua's own
-- NUI surface (that file is a separate, concurrently-active pass's own
-- file this session, per scratchpad/COORDINATION.md's ownership map) --
-- this uses plain, already-established-in-this-resource native text-draw
-- calls instead (client/bonetool.lua's own Draw3DText uses the identical
-- BeginTextCommandDisplayText/AddTextComponentSubstringPlayerName/
-- EndTextCommandDisplayText sequence -- HIGH confidence, not a new/
-- unverified native group, just a different SetDrawOrigin-less 2D
-- screen-space call shape (no world position to anchor to for a
-- persistent HUD banner, so SetDrawOrigin/ClearDrawOrigin are correctly
-- omitted here, unlike that file's own 3D label use)), so it needs no
-- cooperation from that file at all.
--
-- IDLE-VS-ACTIVE POLL, mirroring this resource's own established pattern
-- for a flag-gated per-frame draw (this codebase already avoids a bare
-- `Wait(0)` forever when a feature's own state means there is nothing to
-- draw): a short Wait(0) loop only while training is active, a cheap
-- Wait(500) idle poll otherwise.
-- ======================================================================
local BANNER_TEXT_FONT = 4    -- FONT_CONDENSED -- same choice/citation as client/bonetool.lua's LABEL_TEXT_FONT
local BANNER_TEXT_SCALE = 0.45

local function DrawTrainingBanner()
    SetTextFont(BANNER_TEXT_FONT)
    SetTextScale(BANNER_TEXT_SCALE, BANNER_TEXT_SCALE)
    SetTextColour(255, 190, 40, 235) -- high-visibility amber -- deliberately distinct from ox_lib's own notify palette, so this reads as a standing MODE indicator, not a transient toast
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(locale('training.banner_text', lastKnownReps))
    EndTextCommandDisplayText(0.5, 0.02) -- top-center, normalized screen space
end

CreateThread(function()
    while true do
        if trainingModeActive then
            DrawTrainingBanner()
            Wait(0)
        else
            Wait(500)
        end
    end
end)
