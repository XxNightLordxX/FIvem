--[[
    qbx_k9unit/client/partnership.lua

    Phase 3 (HandlerPartnership registry, PHASE3_SPEC.md §12.0 item 7 /
    §12.3's file-plan entry) — the client half of server/partnership.lua
    (read in full before this file was written; that file's header is the
    authoritative contract for everything below). Delivers exactly what
    fxmanifest.lua's own comment on this file promises, no more: the
    Partner Up consent prompt, an ox_target option, and
    IsPartnered()/GetPartnerServerId() as resource-globals for a future
    radial entry.

    This mirrors client/movement.lua's leash subsystem shape wherever the
    two mechanics are actually alike (the consent handshake), and
    deliberately diverges where server/partnership.lua's own header says a
    partnership must diverge from leash (its "OFFLINE-CAPABLE BY DESIGN" /
    "no unbounded trap" sections) — see "WHY BreakPartnership() DOES NOT
    MIRROR DetachLeash()'S LOCAL PRE-CHECK" below for the one place this
    file's shape is NOT a straight copy of client/movement.lua's.

    ======================================================================
    EVENT/CALLBACK CONTRACT — verified against server/partnership.lua's own
    header (its "EVENT/CALLBACK CONTRACT" section), not re-derived from
    PHASE3_SPEC.md prose alone:

    Server events (client->server), THIS FILE triggers:
    - 'qbx_k9unit:server:requestPartnerUp' (targetServerId: number)
    - 'qbx_k9unit:server:respondPartnerUp' (fromServerId: number, accepted: boolean)
    - 'qbx_k9unit:server:breakPartnership' () -- no arguments; server
      resolves the caller's own citizenid from `source`.

    Client events (server->client), THIS FILE registers:
    - 'qbx_k9unit:client:partnerUpRequest' (fromServerId: number)
      Shown as an accept/decline prompt -- mirrors client/movement.lua's
      leashAttachRequest handler almost line-for-line.
    - 'qbx_k9unit:client:partnershipEstablished' (partnerServerId: number, isK9: boolean)
      Sent individually to EACH party with their OWN role flag (per
      server/partnership.lua's header: "each with their OWN role flag,
      never assume both clients receive the same boolean").
    - 'qbx_k9unit:client:partnershipEnded' (reason: string)
      Sent to whichever party/parties are CURRENTLY ONLINE -- unlike
      leash's leashDetached, server/partnership.lua's header is explicit
      that a partnership can outlive a disconnect, so THIS side must not
      assume the other party is online, and must not assume this is the
      only event that will ever inform this client its partnership ended
      (see the cache-staleness note below).
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes four resource-global (no `local`) functions:
        RequestPartnerUp(targetServerId: number)
            Step 1 of the consent handshake, self-initiated side. Mirrors
            RequestLeashAttach(): re-checks CanShowK9UI() itself (never
            trusts the caller already did), then only ever sends a
            request -- never establishes anything locally.
        BreakPartnership()
            Ends the current partnership, zero consent, always available.
            Exposed for a future client/radial.lua context-sensitive
            "Partner Up"/"Break Partnership" entry, the same dual-mode
            shape that file's existing Attach/Detach Leash item already
            uses (see that file's own header for the precedent) -- NOT
            wired into radial.lua by this pass, since radial.lua is out of
            scope here; a future pass gates the call behind
            `type(BreakPartnership) == 'function'`, this codebase's
            established soft-dependency convention, exactly like every
            other conditionally-defined resource-global here (e.g.
            RestoreInjury, AwardXP/GetXPTier).
        IsPartnered() -> boolean
        GetPartnerServerId() -> number?
            Read-only accessors over this file's local `PartnershipState`
            cache, for that same future radial entry to decide which of
            the two above to call. See "KNOWN CACHE-STALENESS GAP" below
            for an honest limitation on what these can currently promise.
    - THIS FILE calls client/main.lua's CanShowK9UI()/DenyK9UIAccess() for
      the REQUEST side only (see "TERMINATION MUST NEVER BE GATED" below
      for why BreakPartnership() itself does not call either).
    - THIS FILE is the ONLY client file that registers a handler for the
      three partnership client events above, or triggers the three
      partnership server events above -- server/partnership.lua's own
      header states this explicitly ("keep the full subsystem confined to
      one client/one server file", mirroring server/main.lua's own leash
      convention). Do not let a second partnership code path grow in
      client/radial.lua or elsewhere.
    ======================================================================

    TOP-OF-FILE FEATURE GATE -- WHY THE WHOLE FILE, NOT A PER-HANDLER CHECK:
    `if not Config.Features.HandlerPartnership then return end` immediately
    below means this file registers NOTHING at all (no ox_target option, no
    RegisterNetEvent, none of the four resource-globals above are even
    defined) when the flag is false, its default. This is deliberately
    STRONGER than the per-handler gating this resource uses elsewhere (e.g.
    server/kennel.lua's `if not Config.Features.DeployableKennel then return
    end` INSIDE each handler, not at that file's top) -- appropriate here
    specifically because this ENTIRE file is one single feature area with
    no other responsibility to preserve if disabled (unlike
    client/movement.lua, which owns several independently-flagged
    mechanics in one file and could never be gated this bluntly without
    also killing Sit/camera/door-interaction/certify-ox_target along with
    leash). A file-wide top gate is the concrete fix for the exact gap a
    red-team pass just found in client/combat.lua (handlers registered
    unconditionally regardless of that file's own feature flags) --
    applied here from the start rather than retrofitted.
    Server-side safety net this relies on: server/partnership.lua's own
    CheckPartnershipEligibility rejects with 'feature_disabled' whenever
    this flag is false, so no partnership can ever be ESTABLISHED while
    disabled -- this file being fully inert while disabled therefore never
    strands an established pairing with no way to end it. The one
    disclosed edge case that statement does NOT cover (a partnership
    established while the flag was true, then the flag flipped false on a
    later restart) is covered in "KNOWN CACHE-STALENESS GAP" below.
    ======================================================================

    TERMINATION MUST NEVER BE GATED -- BreakPartnership() below calls
    NEITHER CanShowK9UI() NOR DenyK9UIAccess(), and does NOT pre-check
    IsPartnered() before sending. This mirrors client/movement.lua's
    DetachLeash() in spirit (no access-gate on the way out, matching
    PHASE3_SPEC.md §12.0 item 7 point 3's "no unbounded trap" guarantee,
    now applied to a persistent relationship) but goes one step further
    than DetachLeash() by also skipping the LOCAL state pre-check --
    see the next section for exactly why that extra step is required here
    specifically, not optional style.

    WHY BreakPartnership() DOES NOT MIRROR DetachLeash()'S LOCAL PRE-CHECK
    (`if not IsLeashed() then return end`): DetachLeash() can safely
    early-return locally because `leashState` can never be stale --
    a leash pairing is ephemeral, session-scoped state
    (server/main.lua's own framing) that cannot survive this client's own
    resource restart or a reconnect, so `leashState == nil` on this client
    is always an accurate reflection of "not currently leashed."
    `PartnershipState` below has NO such guarantee: server/partnership.lua
    is explicitly DB-backed so a partnership SURVIVES a disconnect/
    reconnect and a resource restart (its own header: "session-spanning,
    plausibly shift-spanning"), but nothing in server/partnership.lua's
    current contract re-sends 'qbx_k9unit:client:partnershipEstablished'
    (or any other event) to a client that reconnects, or whose OWN
    resource restarts, while already genuinely partnered per the DB --
    RefreshPartnershipCache (server-side) silently repopulates the SERVER's
    own cache on PlayerLoaded/onResourceStart but never tells the client
    anything. That means `PartnershipState` can legitimately be `nil` on
    this client immediately after a reconnect/restart EVEN THOUGH the
    player is still actively partnered server-side. If BreakPartnership()
    pre-checked `IsPartnered()` the way DetachLeash() checks `IsLeashed()`,
    a player in exactly that state could never break their own real,
    active, DB-persisted partnership at all -- precisely the "unbounded
    trap" PHASE3_SPEC.md §12.0 item 7 point 3 forbids. Sending
    'qbx_k9unit:server:breakPartnership' UNCONDITIONALLY instead costs
    nothing: server/partnership.lua's own handler is already a safe no-op
    for a citizenid with no active partnership (`DoBreakPartnership`
    returns false, and the caller is told "You are not currently partnered
    with anyone." via NotifyPlayer) -- the server, not this file's cache,
    is the only party that can actually answer "am I partnered right now,"
    exactly this codebase's own "client is never the source of truth"
    principle applied to the one place a stale local cache could otherwise
    strand a player.

    KNOWN CACHE-STALENESS GAP (disclosed, not silently worked around):
    the flip side of the paragraph above is that IsPartnered()/
    GetPartnerServerId() -- the two accessors fxmanifest.lua's own comment
    asks this file to expose for a future radial entry -- CAN under-report
    (return "not partnered" / nil for a player who genuinely IS still
    partnered per the DB) immediately after this client's own reconnect or
    resource restart, for the exact reason above: nothing in
    server/partnership.lua's current contract re-syncs a reconnecting
    client's view of an already-established partnership. This is a real,
    disclosed gap in the CONSUMED contract, not something this file can
    close on its own without a new server-side callback (analogous to
    client/main.lua's existing 'qbx_k9unit:server:hasK9Access' callback,
    but for partnership status) that does not exist in server/
    partnership.lua today -- flagged for whoever wires the future radial
    entry this file's globals exist for for real, so that entry point does
    not silently assume this cache is always accurate. In the meantime the
    practical impact is narrow: BreakPartnership() itself is unaffected
    (see above, by design), the ox_target "Partner Up" option below could
    display available to an already-partnered-but-just-reconnected player,
    but the server's own CheckPartnershipEligibility 'already_partnered'
    check still authoritatively rejects that request with a clear
    notification either way -- a UX rough edge, not a security or
    trap-the-player issue.

    SEPARATE, ALSO DISCLOSED FINDING (not this file's to fix -- reported
    upstream, noted here only because it affects how stale a real
    partnership can get in practice today): server/partnership.lua's own
    header claims "server/certifications.lua calls
    `ForceBreakPartnershipForCitizenId` from three places (RevokeCertification's
    online branch, RevokeCertificationOffline, and the
    QBCore:Server:OnJobUpdate handler's TWO branches)" -- grepped
    server/certifications.lua directly before writing this file and found
    ZERO call sites for `ForceBreakPartnershipForCitizenId` anywhere in
    that file today. A certification revoke or department change
    therefore currently does NOT automatically tear down an active
    partnership server-side, despite the header's claim -- the function
    exists and is exposed correctly, it is simply never called yet. This
    makes BreakPartnership() being unconditionally available (see above)
    more important in practice today, not less: for now it is the ONLY
    reliable way an affected party can end a partnership that should have
    been auto-terminated but was not. Out of scope for this file to fix
    (server/certifications.lua is owned elsewhere) -- reported to the
    orchestrating agent rather than silently patched.
    ======================================================================
]]

if not Config.Features.HandlerPartnership then return end

--- Local-only cached view of the CURRENT partnership, if any. The
--- partnership's existence is server-authoritative
--- (server/partnership.lua's DB-backed registry); this is just this
--- client's own last-known view of it, populated ONLY by the
--- partnershipEstablished handler below (see this file's header "KNOWN
--- CACHE-STALENESS GAP" for why it is not backfilled on reconnect/
--- restart). Not exposed directly -- always go through
--- IsPartnered()/GetPartnerServerId().
--- @type { partnerServerId: number, isK9: boolean }|nil
local PartnershipState = nil

--- @return boolean
function IsPartnered()
    return PartnershipState ~= nil
end

--- @return number?
function GetPartnerServerId()
    return PartnershipState and PartnershipState.partnerServerId or nil
end

--- Step 1 of the consent handshake, self-initiated side. Does NOT
--- establish anything by itself -- see the partnershipEstablished handler
--- below for where the pairing actually activates, after the target
--- accepts. Mirrors client/movement.lua's RequestLeashAttach() almost
--- line-for-line.
--- @param targetServerId number
function RequestPartnerUp(targetServerId)
    -- Re-check, don't trust the caller (ox_target predicate or a future
    -- radial item) already verified this -- cheap client-side sanity
    -- check before bothering the server, which re-validates authoritatively
    -- regardless (server/partnership.lua's CheckPartnershipEligibility).
    if not CanShowK9UI() then
        DenyK9UIAccess()
        return
    end

    if IsPartnered() then
        lib.notify({ title = 'K9 Unit', description = 'You are already partnered.', type = 'error' })
        return
    end

    TriggerServerEvent('qbx_k9unit:server:requestPartnerUp', targetServerId)
    -- The target's client is the one that shows the actual accept/decline
    -- prompt (see partnerUpRequest below), not this one.
    lib.notify({ title = 'K9 Unit', description = 'Partner request sent.', type = 'inform' })
end

--- Ends the current partnership, zero consent required from the other
--- party, at ANY time -- see this file's header "TERMINATION MUST NEVER
--- BE GATED" / "WHY BreakPartnership() DOES NOT MIRROR DetachLeash()'S
--- LOCAL PRE-CHECK" for why this deliberately has NO gate of any kind
--- (not CanShowK9UI(), not a local IsPartnered() pre-check) before sending.
--- Safe to call unconditionally -- server/partnership.lua's own handler is
--- a no-op (with its own notification) for a citizenid with no active
--- partnership.
function BreakPartnership()
    TriggerServerEvent('qbx_k9unit:server:breakPartnership')
end

--- Step 1 of the consent handshake, received on the TARGET's client.
--- Mirrors client/movement.lua's leashAttachRequest handler exactly.
--- @param fromServerId number
RegisterNetEvent('qbx_k9unit:client:partnerUpRequest', function(fromServerId)
    local fromPlayer = GetPlayerFromServerId(fromServerId)
    local fromName = (fromPlayer ~= -1 and GetPlayerName(fromPlayer)) or ('Officer #' .. fromServerId)

    -- If the local player partners/breaks/disconnects mid-prompt, or
    -- either side is no longer eligible by the time they answer, the
    -- server re-validates everything at accept time regardless (see
    -- server/partnership.lua's CheckPartnershipEligibility TOCTOU note) --
    -- this client just needs to send the response and handle a later
    -- rejection gracefully, not assume acceptance always succeeds.
    local response = lib.alertDialog({
        header = 'K9 Partner Request',
        content = ('%s wants to partner up with you. Accept?'):format(fromName),
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })

    TriggerServerEvent('qbx_k9unit:server:respondPartnerUp', fromServerId, response == 'confirm')
end)

--- Step 2 of the consent handshake: the server has confirmed the pairing
--- and told THIS client its role. Sent individually to each party with
--- their own `isK9` value -- do not assume both clients receive the same
--- boolean (server/partnership.lua's own header is explicit about this).
--- @param partnerServerId number
--- @param isK9 boolean -- true only on the client whose OWN character is the K9-role party
RegisterNetEvent('qbx_k9unit:client:partnershipEstablished', function(partnerServerId, isK9)
    PartnershipState = { partnerServerId = partnerServerId, isK9 = isK9 }
    lib.notify({
        title = 'K9 Unit',
        description = isK9 and 'You are now partnered with your handler.' or 'You are now partnered with your K9.',
        type = 'success',
    })
end)

--- The partnership has ended -- self-initiated break by either side, or a
--- server-triggered teardown (e.g. certification revoke, department
--- change, once server/certifications.lua actually calls
--- ForceBreakPartnershipForCitizenId -- see this file's header for the
--- disclosed finding that it does not yet). Sent to whichever client(s)
--- are still online -- server/partnership.lua's header is explicit this
--- side must NOT assume the other party is connected, unlike leash's
--- leashDetached.
--- @param reason string -- e.g. 'broken' (self-initiated) or a plain reason like 'certification_revoked'/'department_changed' (server-triggered); never the raw 'system:<reason>' DB sentinel, which stays server-internal
RegisterNetEvent('qbx_k9unit:client:partnershipEnded', function(reason)
    PartnershipState = nil

    local description = 'Partnership ended.'
    if type(reason) == 'string' and reason ~= '' and reason ~= 'broken' then
        -- Generic fallback rather than a hardcoded exact-string table:
        -- this file doesn't own server/certifications.lua's eventual exact
        -- reason strings, and a future caller of
        -- ForceBreakPartnershipForCitizenId should not need to also edit
        -- this file just to get a readable notification.
        description = ('Partnership ended (%s).'):format(reason)
    end
    lib.notify({ title = 'K9 Unit', description = description, type = 'inform' })
end)

-- Client-side hash set for the "Partner Up" ox_target option's
-- display-only plausibility check below. client/main.lua only exposes
-- IsOwnModelK9() (not its private model-hash table), so this is a small
-- local copy of the same generic Config.Peds-driven check for THIS file's
-- own convenience use -- not a security check, mirroring
-- client/movement.lua's own identical, separately-justified local copy
-- (k9ModelHashesForTargeting) rather than expanding client/main.lua's
-- documented three-function contract for a second file's convenience.
local k9ModelHashesForTargeting = {}
for _, pedEntry in ipairs(Config.Peds) do
    k9ModelHashesForTargeting[GetHashKey(pedEntry.model)] = true
end

local function IsEntityModelK9(entity)
    return k9ModelHashesForTargeting[GetEntityModel(entity)] == true
end

-- Derived from Config.Partnership.ProximityMeters (the REAL server-side
-- range check for establishing a partnership, both at request time and
-- again at accept time -- server/partnership.lua's
-- CheckPartnershipEligibility) rather than a bare magic number, so an
-- installer who tunes that value sees this option's visible range move
-- with it. Kept at HALF that value, same "display-only UI gate,
-- deliberately tighter than the server bound to leave margin against a
-- player drifting between opening ox_target and the server processing the
-- resulting event" reasoning client/movement.lua's own
-- LEASH_TARGET_DISTANCE_FACTOR / CERTIFY_TARGET_DISTANCE_FACTOR already
-- document in full -- not repeated verbatim here, see that file for the
-- complete writeup of this exact tradeoff.
local PARTNER_TARGET_DISTANCE_FACTOR = 0.5

-- Register the "Partner Up" ox_target option on nearby player peds. This
-- is a DISPLAY optimization only -- the server independently re-validates
-- everything for real in CheckPartnershipEligibility
-- (server/partnership.lua), so this predicate doesn't need to be perfect
-- (see this file's header "KNOWN CACHE-STALENESS GAP" for the one honest
-- limitation of the IsPartnered() check below).
exports.ox_target:addGlobalPlayer({
    {
        name = 'qbx_k9unit:partnerUp',
        icon = 'fas fa-handshake',
        label = 'Partner Up',
        distance = PARTNER_TARGET_DISTANCE_FACTOR * Config.Partnership.ProximityMeters,
        canInteract = function(entity, distance, coords, name)
            if IsPartnered() then return false end
            if NetworkGetPlayerIndexFromPed(entity) == PlayerId() then return false end -- can't target self

            -- At least one side should plausibly be a K9 (either us, or
            -- the target's live model) -- cheap client-side plausibility
            -- only, mirrors client/movement.lua's "Attach Leash" predicate.
            return IsOwnModelK9() or IsEntityModelK9(entity)
        end,
        onSelect = function(data)
            local targetPlayer = NetworkGetPlayerIndexFromPed(data.entity)
            if not targetPlayer or targetPlayer == -1 then return end

            RequestPartnerUp(GetPlayerServerId(targetPlayer))
        end,
    },
})
