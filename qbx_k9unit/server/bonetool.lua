--[[
    qbx_k9unit/server/bonetool.lua

    DEV-ONLY BONE-INDEX SWEEP TOOL — Config.Features.BoneSweepDevTool
    (NEW flag this pass, MUST default `false` and MUST NEVER be flipped
    `true` on a production server — see the ACCESS MODEL section below).

    ======================================================================
    WHY THIS EXISTS: three separate research passes for
    Config.Features.PropAttachments failed to find a documented bone NAME
    for a quadruped/animal skeleton, and reading existing open-source dog
    scripts found nobody attaching props to an animal ped at all. The
    reframe that unblocks it: AttachEntityToEntity takes a bone INDEX, not a
    name, and GetWorldPositionOfEntityBone-class natives are entity-type-
    agnostic — so the right method is an in-engine visual sweep by a human
    on a real dev server, not more documentation searching. This file (plus
    client/bonetool.lua) is that sweep tool. It answers the SAME open
    question for Config.Features.FetchMechanic (built concurrently by
    another agent) — see this file's own EXPOSED SURFACE note below for
    exactly what that feature can reuse here rather than building its own
    copy.

    THIS FILE PRODUCES NO ANSWER BY ITSELF. It lets a human connected to a
    real dev server jump to/step through numeric bone indices on their OWN
    current ped and see, with their own eyes (a live debug marker drawn at
    GetWorldPositionOfEntityBone's own result, PLUS an optional real
    CreateObject+AttachEntityToEntity test — see client/bonetool.lua's own
    header for the two-mode PREVIEW/TEST design), which index puts a visible
    marker prop where a vest/harness (or, for FetchMechanic, a fetched item
    held in the mouth) should sit. See this pass's own report for the exact
    question a human still needs to answer.

    ======================================================================
    ACCESS MODEL — same two-factor gate this task's own brief requires
    (explicit config flag AND an ACE permission check), following
    server/admin.lua's precedent exactly (read that file's own "ACCESS
    MODEL" header section before changing anything here):
      1. Config.Features.BoneSweepDevTool must be `true` — checked AT
         COMMAND-REGISTRATION TIME in the onResourceStart block below, not
         merely inside the handler. If it's not `true`, the '/k9bonetool'
         command is never registered at all, matching this resource's
         established "flag off means genuinely inert" convention.
      2. IsPlayerAceAllowed(tostring(source), Config.BoneSweepTool.AcePermission)
         — re-checked on EVERY invocation, inside the handler, exactly like
         server/admin.lua's IsAuthorizedAdmin.
    Both must hold. Neither alone is sufficient — a server owner who
    accidentally leaves the flag on must still have never granted the ACE
    to anyone for this to do anything, and vice versa.

    CONSOLE (source == 0) IS DELIBERATELY NOT SUPPORTED, UNLIKE
    server/admin.lua's own console carve-out: every subcommand this tool
    exposes acts on "your own current ped" (see EVENT CONTRACT below) —
    the server console has no client and no ped for that concept to apply
    to. This is a narrower, simpler answer than admin.lua's own
    read-only-query carve-out needed, not an oversight; flagged explicitly
    per this resource's own "disclose access-model judgment calls, don't
    decide them silently" convention.

    THIS TOOL NEVER TOUCHES NETWORKED STATE: every subcommand below is
    forwarded, unchanged, to the ONE calling client's own client-side
    handler (client/bonetool.lua). The PREVIEW half ('goto'/'next'/'prev')
    never creates any entity at all — it only draws a per-frame debug marker
    at a queried bone position. The TEST half ('test') creates its object
    with CreateObject's isNetwork = false (a purely local visual aid — see
    client/bonetool.lua's own header). There is no server-side registry of
    "who currently has a test object attached" and no broadcast to any other
    client. This means the tool has a structurally smaller entity-leak blast
    radius than every other prop-creating feature in this resource: a test
    prop that somehow survives its intended cleanup is, at worst, a
    LOCAL-ONLY object on the one connected admin's own client, gone the
    moment that client disconnects or this resource stops
    (client/bonetool.lua still runs its own onResourceStop/'stop' cleanup
    regardless — this is a structural property of local-only objects, not a
    reason to skip the explicit cleanup path).

    ======================================================================
    EVENT CONTRACT:
    Client events (RegisterNetEvent, server->client), sent ONLY to the one
    calling client, never broadcast:
    - 'qbx_k9unit:client:boneToolCommand' (subcommand: string, index: number?)
      [client/bonetool.lua] subcommand ∈ {'goto', 'next', 'prev', 'test', 'stop'}.
      'goto' carries a validated, clamped integer index in [0, MaxBoneIndex];
      every other subcommand carries no index at all — the CLIENT owns its
      own current-index state (this file deliberately does not track it
      server-side; there is nothing security-relevant about which integer a
      dev-tool marker currently sits at).

    Commands (server-registered):
    - '/k9bonetool <goto|next|prev|test|stop> [index]'
        goto <index>  — preview this exact bone index (a live debug marker
                        at its GetWorldPositionOfEntityBone position; replaces
                        whatever index was previously previewed).
        next / prev   — step the CLIENT's own current preview index by +/-1
                        (clamped to [0, MaxBoneIndex] client-side).
        test          — real CreateObject + AttachEntityToEntity at the
                        CLIENT's own current preview index, for a final
                        visual confirmation of the actual attach call
                        (replaces any previous test object).
        stop          — stops the preview marker and removes any test object.

    ======================================================================
    EXPOSED SURFACE FOR FetchMechanic (built concurrently, per this pass's
    own task brief): NOTHING beyond this command itself needs to be
    exposed — the FetchMechanic agent's own dev-testing workflow is simply
    "connect to a dev server, run '/k9bonetool goto <n>' repeatedly while
    playing as a K9 (or whatever model FetchMechanic targets), read off the
    index that visually looks right for a mouth/head attach point, and hard-
    code that into their own feature's config." No shared server-side state,
    no shared function signature, is needed for that workflow — the tool
    IS the shared surface. The one thing this file's sibling,
    client/bonetool.lua, DOES also expose as a resource-global (not
    duplicated) is client/propattachment.lua's AttachPropToOwnPed /
    DetachAndDeleteProp pair (client/bonetool.lua calls those directly
    rather than re-implementing its own CreateObject/AttachEntityToEntity
    sequence) — FetchMechanic's own client file should call those same two
    functions for its actual (non-dev-tool) attach, rather than hand-rolling
    a third copy of that mechanic. See client/propattachment.lua's own
    header for that function pair's full contract.

    FILE-TO-FILE CONTRACT:
    - THIS FILE calls `NewCooldown()` (server/cooldowns.lua) at file-load
      time — must load after that file.
    - THIS FILE exposes no resource-global functions of its own.

    CONFIG THIS FILE ASSUMES EXISTS — NOT owned by this file (coder-architect
    owns config.lua/fxmanifest.lua/.luacheckrc for this task; see this
    pass's own hand-off note for the exact blocks needed):
      Config.Features.BoneSweepDevTool : boolean (NEW; default false; MUST
                                          stay false on any production server)
      Config.BoneSweepTool.AcePermission     : string
      Config.BoneSweepTool.TestPropModel     : string  -- only used by the 'test' subcommand; the 'goto'/'next'/'prev' preview needs no model at all (pure position query)
      Config.BoneSweepTool.MaxBoneIndex      : integer >= 0
      Config.BoneSweepTool.TestOffsetX/Y/Z   : number
      Config.BoneSweepTool.CommandCooldownMs : number
]]

-- NOTE: 'goto' is a reserved word in Lua 5.4, so its key must be bracketed
-- (['goto'] = true) rather than the bare `goto = true` shorthand every
-- other key here uses.
local VALID_SUBCOMMAND_SET = { ['goto'] = true, next = true, prev = true, test = true, stop = true }

--- Sends an ox_lib notification to a specific player. Duplicated (not
--- shared) per this resource's established convention — see
--- server/kennel.lua's own NotifyPlayer comment.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    TriggerClientEvent('ox_lib:notify', target, {
        title = 'K9 Unit — Bone Tool',
        description = description,
        type = notifyType or 'inform',
    })
end

-- REFACTOR_ROADMAP.md item 1 convention: per-source rate limit on running
-- this command at all — spam/abuse guard only (this is an admin-only tool,
-- but a misbehaving or scripted client is still worth throttling, same
-- reasoning as server/admin.lua's own AuditCooldown).
local BoneToolCooldown = NewCooldown()
BoneToolCooldown.RegisterPlayerDropped()

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end

    if not (Config.Features and Config.Features.BoneSweepDevTool == true) then
        return -- feature disabled (or not yet configured) — the command is never registered at all
    end

    assert(type(Config.BoneSweepTool) == 'table', '[qbx_k9unit] Config.Features.BoneSweepDevTool is true but Config.BoneSweepTool is missing.')
    assert(type(Config.BoneSweepTool.AcePermission) == 'string' and Config.BoneSweepTool.AcePermission ~= '', '[qbx_k9unit] Config.BoneSweepTool.AcePermission must be a non-empty string.')
    assert(type(Config.BoneSweepTool.TestPropModel) == 'string' and Config.BoneSweepTool.TestPropModel ~= '', '[qbx_k9unit] Config.BoneSweepTool.TestPropModel must be a non-empty string.')
    assert(type(Config.BoneSweepTool.MaxBoneIndex) == 'number' and Config.BoneSweepTool.MaxBoneIndex >= 0, '[qbx_k9unit] Config.BoneSweepTool.MaxBoneIndex must be a number >= 0.')
    for _, key in ipairs({ 'TestOffsetX', 'TestOffsetY', 'TestOffsetZ' }) do
        assert(type(Config.BoneSweepTool[key]) == 'number', ('[qbx_k9unit] Config.BoneSweepTool.%s must be a number.'):format(key))
    end
    assert(type(Config.BoneSweepTool.CommandCooldownMs) == 'number' and Config.BoneSweepTool.CommandCooldownMs >= 0, '[qbx_k9unit] Config.BoneSweepTool.CommandCooldownMs must be a number >= 0.')

    RegisterCommand('k9bonetool', function(src, args)
        if src == 0 then
            -- Console carve-out is DELIBERATELY absent here — see this
            -- file's header ACCESS MODEL section.
            print('[qbx_k9unit] /k9bonetool must be run by a connected player, not the server console.')
            return
        end

        if not IsPlayerAceAllowed(tostring(src), Config.BoneSweepTool.AcePermission) then
            NotifyPlayer(src, 'You are not authorized to use this tool.', 'error')
            return
        end

        if not BoneToolCooldown.Consume(src, Config.BoneSweepTool.CommandCooldownMs) then
            return -- silent no-op: rate-limited, matches this resource's own bark/leash-request/certify-action convention
        end

        local sub = args[1]
        if not VALID_SUBCOMMAND_SET[sub] then
            NotifyPlayer(src, 'Usage: /k9bonetool <goto|next|prev|test|stop> [index]', 'error')
            return
        end

        if sub == 'goto' then
            local index = tonumber(args[2])
            if not index then
                NotifyPlayer(src, 'Usage: /k9bonetool goto <index>', 'error')
                return
            end
            index = math.floor(index)
            if index < 0 then index = 0 end
            if index > Config.BoneSweepTool.MaxBoneIndex then index = Config.BoneSweepTool.MaxBoneIndex end
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, 'goto', index)
        else
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, sub, nil)
        end
    end, false)

    print('[qbx_k9unit] bonetool.lua: dev-only bone-index sweep tool registered (/k9bonetool). DO NOT enable Config.Features.BoneSweepDevTool on a production server.')
end)
