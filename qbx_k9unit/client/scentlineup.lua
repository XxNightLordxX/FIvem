--[[
    qbx_k9unit/client/scentlineup.lua

    SCENT LINEUP (Config.Features.ScentLineup) -- client half. Companion to
    server/scentlineup.lua -- read that file's header FIRST, especially
    "THE SECURITY SHAPE OF THIS FEATURE": the answer never exists on any
    client, this one included, before a pick is committed.

    WHY THIS FILE IS SO SMALL: every other message in this feature (usage
    errors, invite-sent confirmation, accept progress, the lineup-ready
    roster, the final reveal, every cancellation) is plain text pushed
    through server/notify.lua's NotifyPlayer -> the existing, already-wired
    'ox_lib:notify' client event -- none of that needs a line of code in
    this file. The ONLY thing that genuinely requires client-side logic is
    the one interactive step a plain toast can't do: showing the invited
    player a real accept/decline decision and sending their answer back.
    That is this file's entire job.

    ======================================================================
    EVENT CONTRACT (server -> client):
    'qbx_k9unit:client:scentLineupInvite' (fromServerId: number,
    inviteWindowMs: number) -- sent to exactly one invited player, never
    broadcast (server/scentlineup.lua's /k9lineup handler sends this
    individually per target). Shows a real accept/decline dialog and
    reports the answer back via 'qbx_k9unit:server:respondScentLineupInvite'
    (fromServerId, accepted: boolean) -- the ONLY net event this file ever
    sends, mirroring client/partnership.lua's respondPartnerUp shape
    byte-for-byte (same dialog API, same labels, same origin guard).

    SOURCE-ORIGIN GUARD: `source ~= 65535` is this handler's first
    statement, per DEVELOPER_REFERENCE.md#trust-boundary's
    documented pattern (FiveM's own "the server sends net id 65535" rule)
    already applied identically by client/partnership.lua/
    client/screenfx.lua in this resource. Forging this event locally would
    only pop this client's own dialog with no server contact -- annoying,
    not a capability grant (accepting still round-trips through
    server/scentlineup.lua's own re-validated state, exactly like
    partnership's own respondPartnerUp) -- but the guard is free and keeps
    this file consistent with the resource-wide convention rather than
    being an unexplained exception to it.

    NO LOAD-ORDER DEPENDENCY: this file calls no other client file's
    global, at load time or call time -- only bare CFX natives
    (GetPlayerFromServerId, GetPlayerName), ox_lib (`lib.alertDialog`, a
    hard dependency per fxmanifest.lua), and `TriggerServerEvent`. It may
    load anywhere after client/main.lua; it sits next to
    client/partnership.lua as the thematically closest existing file (same
    consent-dialog shape). Reading `Config.Features.ScentLineup` below adds
    no load-order requirement of its own: Config is a shared_script (loads
    before every client_script in fxmanifest.lua), the same "reads Config,
    calls no other file's global" shape this note already describes.

    FEATURE GATE: every sibling file in this batch (client/scenttrail.lua,
    client/sarcalls.lua, client/pursuitsprint.lua) opens with
    `if not Config.Features.<Name> then return end`; this file needs the
    same gate, checked FIRST, matching this resource's universal placement
    convention. Without it, this file's
    'qbx_k9unit:client:scentLineupInvite' handler would register
    UNCONDITIONALLY even when Config.Features.ScentLineup is explicitly
    false server-side. The blast radius stays small regardless
    (server/scentlineup.lua's own /k9lineup command already gates on the
    same flag before ever sending this event, and the source-origin guard
    above still applies), but this resource's rule is that a disabled
    feature is INERT, not merely unreachable in practice -- a registered
    handler is a handler someone can still try to reach.
]]

if not Config.Features.ScentLineup then return end

RegisterNetEvent('qbx_k9unit:client:scentLineupInvite', function(fromServerId, inviteWindowMs)
    if source ~= 65535 then return end
    if type(fromServerId) ~= 'number' then return end

    -- Same "resolve a display name from a server id, fall back to the
    -- shared Officer #%d locale key" idiom as client/partnership.lua's own
    -- respondPartnerUp prompt and client/movement.lua's leash-request
    -- prompt -- reused deliberately, not re-derived, per this resource's
    -- "reuse existing key, don't mint a near-duplicate" locale convention.
    local fromPlayer = GetPlayerFromServerId(fromServerId)
    local fromName = (fromPlayer ~= -1 and GetPlayerName(fromPlayer)) or locale('movement.officer_fallback_name', fromServerId)

    local seconds = math.floor((tonumber(inviteWindowMs) or 30000) / 1000)

    -- server/scentlineup.lua re-validates everything about this session at
    -- response time regardless (does the caller still have a live pending
    -- invite, does it still match this exact conductor) -- this dialog
    -- just needs to ask and send the answer, not assume acceptance always
    -- succeeds.
    local response = lib.alertDialog({
        header = locale('scentlineup.invite_header'),
        content = locale('scentlineup.invite_received', fromName, seconds),
        centered = true,
        cancel = true,
        labels = { confirm = locale('movement.accept_label'), cancel = locale('movement.decline_label') },
    })

    TriggerServerEvent('qbx_k9unit:server:respondScentLineupInvite', fromServerId, response == 'confirm')
end)
