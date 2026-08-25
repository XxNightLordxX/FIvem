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

    OPERATIONAL CAVEAT (task requirement — also stated in config.lua's own
    Config.Features.BoneSweepDevTool comment; restated here because THIS
    file is the one that actually acts on it): the flag above is read ONCE,
    in the onResourceStart block below, to decide whether to
    RegisterCommand '/k9bonetool' at all. Flipping
    Config.Features.BoneSweepDevTool from true back to false WITHOUT a
    resource restart does NOT unregister the command — it stays reachable
    (still gated by the ACE check inside the handler, re-checked on every
    invocation) until the next restart. client/bonetool.lua's own
    registration gate has the identical property for its event
    handler/draw thread. Never treat "I turned the flag off" as sufficient
    by itself to consider this tool inert on a server where it was ever
    turned on, without also restarting the resource.

    CONSOLE (source == 0) IS DELIBERATELY NOT SUPPORTED, UNLIKE
    server/admin.lua's own console carve-out: every subcommand this tool
    exposes acts on "your own current ped" (see EVENT CONTRACT below) —
    the server console has no client and no ped for that concept to apply
    to. This is a narrower, simpler answer than admin.lua's own
    read-only-query carve-out needed, not an oversight; flagged explicitly
    per this resource's own "disclose access-model judgment calls, don't
    decide them silently" convention.

    GETPEDBONEINDEX — CONFIRMED AGAINST PRIMARY SOURCE THIS PASS, AND THE
    CONCLUSION ON WHETHER THIS TOOL SHOULD CONVERT THROUGH IT (task item 3
    — full writeup in client/bonetool.lua's own header, since the actual
    native call happens there; summarized here for anyone who only reads
    this file): `GET_PED_BONE_INDEX(Ped ped, int boneId)`
    (0x3F428D08BE5AAE31, read directly off a fresh clone of
    citizenfx/natives, not carried over from an earlier pass) converts a
    semantic `ePedBoneId` value into the raw index AttachEntityToEntity
    wants — the exact conversion AttachEntityToEntity's own doc points at
    ("This is different to boneID, use GET_PED_BONE_INDEX..."). That same
    enum lists animal-only entries (SKEL_Tail_01..05, SKEL_SADDLE), which is
    corroborating evidence — not proof — that some of these ids resolve to
    something real on an `a_c_*` skeleton. CONCLUSION: yes, worth exposing
    as a FAST-PATH shortcut (the new 'known' subcommand below), but never as
    a replacement for the raw sweep, because (1) that native's own doc page
    has an EMPTY "Return value" section — this pass could not confirm its
    not-found convention, so 'known' reports every raw value unfiltered
    rather than silently filtering "hits", and (2) even a real resolved
    index isn't guaranteed to be anatomically where the human-skeleton name
    suggests on a differently-rigged model — every 'known' result is still
    just a candidate for the human to 'goto' and confirm with their own
    eyes, never a trusted answer by itself.

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
    - 'qbx_k9unit:client:boneToolCommand' (subcommand: string, arg: number?)
      [client/bonetool.lua] subcommand ∈ {'goto', 'next', 'prev', 'test',
      'known', 'stop'} ('help' never reaches the client at all — see below).
      'goto' carries a validated, clamped integer index in [0, MaxBoneIndex].
      'next'/'prev' now carry an optional positive integer STEP (NOT an
      index — how many indices to move, defaulting to 1, validated/clamped
      here before ever being sent, and re-validated client-side too). Every
      other subcommand carries no argument at all — the CLIENT owns its own
      current-index state (this file deliberately does not track it
      server-side; there is nothing security-relevant about which integer a
      dev-tool marker currently sits at).

    Commands (server-registered):
    - '/k9bonetool <goto|next|prev|test|stop|known|help> [arg]'
        goto <index>  — preview this exact bone index (a live debug marker
                        AND an on-screen index-number label at its
                        GetWorldPositionOfEntityBone position; replaces
                        whatever index was previously previewed).
        next [step]   — step the CLIENT's own current preview index forward
                        by [step] (default 1, must be a positive integer;
                        clamped to [0, MaxBoneIndex] client-side). A human
                        sweeping up to MaxBoneIndex (200 by default)
                        benefits from being able to skip ahead rather than
                        stepping one at a time the whole way.
        prev [step]   — same, stepping backward.
        test          — real CreateObject + AttachEntityToEntity at the
                        CLIENT's own current preview index, for a final
                        visual confirmation of the actual attach call
                        (replaces any previous test object).
        stop          — stops the preview marker and removes any test object.
        known         — CLIENT-LOCAL ONLY (task item 3's GetPedBoneIndex
                        fast-path — see the GETPEDBONEINDEX section above):
                        resolves a curated list of documented ePedBoneId
                        semantic names against the caller's own live ped and
                        reports every raw result via chat + console. Never
                        changes the current preview index — purely a
                        candidate shortlist to 'goto' into and confirm.
        help          — handled ENTIRELY here, server-side: no client
                        dispatch at all, just the full goto/next/prev/known/
                        test/stop/record-your-result workflow via
                        NotifyPlayer, so a human can read it before
                        confirming anything client-side is even working.

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
      Config.BoneSweepTool.CommandCooldownMs : number > 0 (NOT >= 0 -- see the
                                          onResourceStart assert below: this
                                          value is read fresh at call time by
                                          a NewCooldown() with no constructor
                                          default, so 0/negative fails CLOSED
                                          -- permanently on cooldown after one
                                          use -- rather than meaning "no
                                          cooldown")
]]

-- NOTE: 'goto' is a reserved word in Lua 5.4, so its key must be bracketed
-- (['goto'] = true) rather than the bare `goto = true` shorthand every
-- other key here uses.
local VALID_SUBCOMMAND_SET = { ['goto'] = true, next = true, prev = true, test = true, stop = true, known = true, help = true }

-- Full workflow reference — shown both on an invalid/missing subcommand and
-- via the explicit 'help' subcommand (task requirement: the tool must tell
-- a human how to record what they find, not just show a marker). Built
-- once via table.concat, same multi-line-notify pattern server/admin.lua's
-- own NotifyPlayer call sites already establish as safe for ox_lib's
-- notify (embedded '\n' renders as real line breaks there).
local BONE_TOOL_USAGE = table.concat({
    'K9 Bone Sweep Tool -- DEV SERVER ONLY.',
    '/k9bonetool goto <index>  -- preview one exact index (marker + on-screen label)',
    '/k9bonetool next [step]   -- step the preview forward (default 1)',
    '/k9bonetool prev [step]   -- step the preview backward (default 1)',
    '/k9bonetool known         -- list candidate indices from known bone names (still verify with goto)',
    '/k9bonetool test          -- really attach a marker prop at the current preview index',
    '/k9bonetool stop          -- stop the preview and remove any test prop',
    'Found the right index? Record it in config.lua:',
    '  Config.PropAttachments.boneIndex (vest) or Config.FetchMechanic.mouthBoneIndex (fetch mouth carry).',
}, '\n')

--- Sends an ox_lib notification to a specific player, using this file's own
--- 'K9 Unit — Bone Tool' title. Deliberately kept as a thin LOCAL wrapper
--- (same name, shadowing the resource-global on purpose) rather than
--- flattened onto server/notify.lua's shared implementation directly at
--- every call site below — see that file's header "TWO CALL SITES
--- DELIBERATELY KEPT AS LOCAL WRAPPERS" section for the full reasoning
--- (this title is a deliberate, player-visible per-subsystem difference,
--- not an accident). The explicit `_G.` prefix below is required, not
--- decorative: a bare `NotifyPlayer(...)` call inside this same-named local
--- function's own body would resolve to this local (already in scope
--- inside its own body) and recurse forever instead of reaching the shared
--- global.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    _G.NotifyPlayer(target, description, notifyType, 'K9 Unit — Bone Tool')
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
    -- MUST be strictly > 0, not >= 0: BoneToolCooldown below is a
    -- server/cooldowns.lua NewCooldown() instance with no constructor
    -- default, so this value is read fresh at every call-time IsOnCooldown
    -- check (see BoneToolCooldown.Consume below). That file's own
    -- IsValidThreshold rejects 0/negative as "no cooldown" and instead
    -- treats it as PERMANENTLY on cooldown (fail-closed) after the very
    -- first use — a 0 here does not mean "unthrottled," it means the tool
    -- locks out after exactly one invocation until this resource restarts.
    -- This mirrors cooldowns.lua's own AssertValidDefaultThreshold guard
    -- (`value > 0`) and server/admin.lua's identical positive-floor
    -- requirement on its own CommandCooldownMs, applied here at the
    -- call-time-threshold call shape instead of the constructor-default
    -- shape.
    assert(type(Config.BoneSweepTool.CommandCooldownMs) == 'number' and Config.BoneSweepTool.CommandCooldownMs > 0, '[qbx_k9unit] Config.BoneSweepTool.CommandCooldownMs must be a number > 0 -- 0 or negative does NOT mean "no cooldown" here, it means this tool fails closed (permanently blocked) after one use. See server/cooldowns.lua\'s fail-closed threshold handling.')

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
            NotifyPlayer(src, BONE_TOOL_USAGE, 'error')
            return
        end

        if sub == 'help' then
            -- Handled ENTIRELY here — no client dispatch needed for plain
            -- text, and a human should be able to read the full workflow
            -- even before confirming anything client-side is working.
            NotifyPlayer(src, BONE_TOOL_USAGE, 'inform')
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
        elseif sub == 'next' or sub == 'prev' then
            -- args[2], if present, is a STEP size (how many indices to
            -- move), never an absolute index — see this file's header
            -- EVENT CONTRACT. Defaults to 1, matching the tool's original
            -- one-at-a-time behavior; a human sweeping up to MaxBoneIndex
            -- (200 by default) benefits from being able to skip ahead.
            local step = 1
            local parsed = tonumber(args[2])
            if parsed then
                step = math.max(1, math.floor(parsed))
            end
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, sub, step)
        else
            -- 'test' / 'stop' / 'known' — no argument of any kind.
            TriggerClientEvent('qbx_k9unit:client:boneToolCommand', src, sub, nil)
        end
    end, false)

    print('[qbx_k9unit] bonetool.lua: dev-only bone-index sweep tool registered (/k9bonetool). DO NOT enable Config.Features.BoneSweepDevTool on a production server.')
end)
