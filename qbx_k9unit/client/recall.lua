--[[
    qbx_k9unit/client/recall.lua

    Client half of server/recall.lua (DEVELOPER_REFERENCE.md §12.5.1's
    "Recall actor" -- read that file's header in full before touching this
    one; it is the authoritative contract for everything below). Provides
    the handler-facing entry point for Recall -- a chat command.
    client/radial.lua also calls the exported `RequestRecall()` below from
    its own "Recall" item -- the command stays as an additional,
    equally-valid entry point, never replaced by it. Same "global helper,
    private per-file state" convention as client/combat.lua's
    `RequestBiteHold()`/`RequestDrag()` or client/partnership.lua's
    `BreakPartnership()`.

    ======================================================================
    TERMINATION MUST NEVER BE GATED -- `RequestRecall()` below calls NEITHER
    `CanShowK9UI()` NOR `DenyK9UIAccess()`, unlike every SELF-INITIATED
    trigger in this resource (`RequestBiteHold`/`RequestTakedown`/
    `RequestDrag`, `RequestPartnerUp`). Mirrors client/partnership.lua's
    `BreakPartnership()` and client/movement.lua's `DetachLeash()` in
    spirit -- Recall is a TERMINATION action, not an initiation, and
    server/recall.lua's own header names this exact "gate the initiation,
    never the termination" split as this resource's binding invariant, not
    a style choice.

    Also, unlike `RequestBiteHold`'s own "no eligible target in range" local
    pre-check, this function performs NO local plausibility check of any
    kind before sending -- there is nothing to search for client-side
    (Recall targets "my own partner K9," resolved entirely server-side, see
    server/recall.lua's own "SERVER-AUTHORITATIVE RESOLUTION" section) and
    no local state (like `IsPartnered()`) worth pre-checking here, for the
    exact same reason client/partnership.lua's `BreakPartnership()` skips
    its own equivalent local pre-check: this client's own view of whether
    it is partnered, or of what its partner is currently doing, can be
    stale (reconnect/restart -- see client/partnership.lua's own "KNOWN
    CACHE-STALENESS GAP" section), and a stale local "nothing to recall"
    read must never be able to withhold a request the server can otherwise
    correctly resolve.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Exposes `RequestRecall()` as a bare global (this resource's
      established "global helper, private per-file state" convention).
      client/radial.lua's own "Recall" item calls this exact function --
      this file needed no change for that to happen.
    - Registers the `k9recall` chat command as its concrete entry point.
      Command REGISTRATION is gated on `Config.Features.Recall` only (see
      the top-of-file gate below); command AVAILABILITY is deliberately NOT
      an authorization decision (see "TERMINATION MUST NEVER BE GATED"
      above): this command is registered for EVERY player regardless of K9
      involvement, exactly like server/recall.lua's own event handler
      applies no HasK9Access/CanShowK9UI check either. A player who is not
      genuinely partnered with an online, engaged K9 simply receives the
      server's own "nothing to recall" notification -- never a client-side
      denial.
    - No `RegisterNetEvent` handlers exist in this file -- Recall has no
      server->client relay event of its own; the K9's own existing
      target-side/holder-side teardown handlers (`endBiteHold`,
      `endForceRagdoll`, `dragEnded`, `endDragSpeedLimit`, etc., all
      client/combat.lua) already fire correctly for a `'recalled'` end
      reason, since server/combat.lua's `EndHold` is effect-agnostic about
      *why* an engagement ended (see server/recall.lua's own header "SCOPE"
      section). Nothing new is needed on the receiving end.
    ======================================================================
]]

if not Config.Features.Recall then return end

--- Calls the local player's own established K9 partner back from whatever
--- engagement (bite/takedown/drag) that K9 currently has active, if any.
--- Sends NO arguments and NO client-claimed identifier of any kind --
--- server/recall.lua resolves "which K9" entirely from server-held
--- partnership state, keyed off `source`. Safe to call unconditionally, at
--- any time, regardless of this client's own K9 involvement or
--- certification state -- see this file's header "TERMINATION MUST NEVER BE
--- GATED".
function RequestRecall()
    TriggerServerEvent('qbx_k9unit:server:requestRecall')
end

RegisterCommand('k9recall', function()
    RequestRecall()
end, false)
