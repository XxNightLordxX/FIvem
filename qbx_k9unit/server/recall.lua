--[[
    qbx_k9unit/server/recall.lua

    Phase 3 implementation, PHASE3_SPEC.md §12.5.1's "Recall actor" (§12.0
    item 7, Revision 5's resolution) -- the one consumer server/partnership.lua's
    own "FUTURE CONSUMERS" header section names as still unbuilt for
    BiteAndHold's Recall path, and this resource's PRIMARY escape hatch for
    every one of server/combat.lua's non-consensual engaged states
    (bite-and-hold, non-lethal takedown's ragdoll window, and prop
    dragging) -- see "SCOPE: ALL THREE ENGAGEMENT TYPES, NOT JUST
    BITEANDHOLD" below for why this is not narrowed to §12.5.1's own literal
    text.

    CONCRETE BEHAVIOR: a certified handler's own established K9 PARTNER
    (server/partnership.lua's `Partnerships` registry -- never a
    client-claimed "who is my K9" relationship) can, at ANY time,
    unconditionally end whatever engagement (bite/takedown/drag) THAT K9
    currently holds against a target. This is a PARTNER-issued action,
    distinct from the K9 player's OWN self-release actions
    (`releaseBiteHold`/`releaseDrag`, server/combat.lua) -- a K9 cannot
    "recall" themselves through this event; they already have their own
    release controls for that, and this file rejects that case explicitly
    (see the event handler below).

    ======================================================================
    NO UNBOUNDED TRAP -- THE LOAD-BEARING INVARIANT THIS FILE EXISTS TO
    SATISFY (read before touching a single line below): PHASE3_SPEC.md's own
    §12.0 item 4 names BiteAndHold/NonLethalTakedown/PropDragging's hard
    duration/distance caps as "this mechanic's version of the leash's 'no
    unbounded trap' guarantee -- not merely a balance knob, load-bearing for
    this feature's non-consensual design being acceptable at all." Recall is
    this resource's OTHER, complementary half of that same guarantee: the
    caps bound how long an engagement can last even if nobody intervenes;
    Recall is the intervention that can end it sooner, on demand.
    Consequently, THE HANDLER'S OWN REQUEST TO RECALL MUST NEVER BE GATED
    BEHIND HasK9Access/CanShowK9UI OR ANY OTHER ACCESS/CERTIFICATION CHECK,
    ON EITHER PARTY -- a handler whose OWN certification is revoked, or
    whose K9 partner's certification is revoked, mid-bite must still be able
    to call their dog off. This exact class of bug (a termination/escape
    path silently gated behind the same access check that gates INITIATING
    the thing being escaped) has already shipped once in this codebase and
    was fixed -- do not reintroduce it here. The ONLY gates this file's
    event handler applies are: (a) `Config.Features.Recall` itself
    (registration-level -- see the top-of-file gate below; this decides
    whether the mechanic EXISTS at all on this server, never whether a given
    request is authorized), (b) a per-caller rate limit (spam prevention
    only, see `RecallCooldown` below), and (c) that the CALLER is genuinely,
    per server-authoritative state, the target K9's established partner --
    never HasK9Access, never CanShowK9UI, on either party.
    ======================================================================

    SCOPE: ALL THREE ENGAGEMENT TYPES, NOT JUST BITEANDHOLD --
    PHASE3_SPEC.md §12.5.1's own prose names Recall specifically for
    BiteAndHold ("ending early on ... the K9's registered partner ...
    issuing 'Recall'"). This file generalizes that to whatever engagement
    server/combat.lua's own `K9ActiveEffect[k9Src]` currently names for the
    partner K9 -- bite, takedown, or drag alike -- via server/combat.lua's
    own `EndActiveEffectForHolder(holderSrc)` accessor, rather than
    re-deriving a bite-only check here. Justification: (1) server/combat.lua's
    own `EndHold` is ALREADY effect-agnostic (a single shared teardown for
    all three, see that function's own header) -- there is no bite-specific
    machinery this file would need to skip for takedown/drag; (2)
    PHASE3_SPEC.md §12.0 item 4's "no unbounded trap" guarantee is framed
    identically across all three mechanics, not as a BiteAndHold-only
    concern; (3) narrowing Recall to bite-only would leave a handler with no
    way to call off their OWN partner K9 mid-drag or mid-takedown-ragdoll-
    window, which is a strictly WORSE "unbounded trap" posture than
    generalizing produces. Flagged explicitly as a deliberate scope
    decision, not a silent reading of the spec's literal text -- whoever
    next reconciles PHASE3_SPEC.md's prose with shipped behavior should
    update §12.5.1's own text to match, not the other way around.

    ======================================================================
    SERVER-AUTHORITATIVE RESOLUTION -- NO CLIENT-SUPPLIED IDENTIFIERS AT
    ALL: the client event below (`qbx_k9unit:server:requestRecall`) takes NO
    arguments. "Which K9 does this handler recall" is derived ENTIRELY from
    server-held state: `source` -> citizenid (qbx_core) -> that citizenid's
    active partner (server/partnership.lua's `GetActivePartnerCitizenId`,
    never a client-claimed relationship) -> that partner's live server id
    (`exports.qbx_core:GetPlayerByCitizenId`) -> that K9's own currently
    active engagement (server/combat.lua's `K9ActiveEffect`, entirely
    server-side, read only through `EndActiveEffectForHolder`). There is
    nothing for a client to spoof here beyond "which source is calling this
    event" (already whoever `source` genuinely is, per FiveM's own
    event-source guarantee) -- a strictly narrower trust surface than every
    other combat event in this file's sibling server/combat.lua, none of
    which this file re-implements or duplicates.
    ======================================================================

    FILE-TO-FILE CONTRACT:
    - Calls `GetActivePartnerCitizenId(citizenid)` (server/partnership.lua),
      guarded by `type(...) == 'function'` -- runtime existence guard, not a
      load-order assumption, per this resource's established convention
      (see server/medkit.lua's `RestoreInjury` reuse / server/defense.lua's
      identical guard on this exact function for the precedent this
      mirrors). Never reaches into server/partnership.lua's own `local`
      `Partnerships` table directly.
    - Calls `EndActiveEffectForHolder(holderSrc)` (server/combat.lua), same
      runtime-existence-guard convention -- this file never reaches into
      server/combat.lua's own `local` `ActiveHolds`/`K9ActiveEffect` tables
      or re-implements `EndHold`'s teardown logic itself.
    - Calls `NewCooldown()` (server/cooldowns.lua) at THIS file's own
      file-load time -- per that file's own header, THIS FILE must load
      after server/cooldowns.lua in fxmanifest.lua's `server_scripts`.
    - No ordering dependency on server/partnership.lua or server/combat.lua
      either way (both consumed through runtime existence guards) -- this
      file can be placed anywhere in fxmanifest.lua's `server_scripts` list
      after server/cooldowns.lua, mirroring server/defense.lua's own
      identical "no load-order requirement, recommended placement only"
      note for the same `GetActivePartnerCitizenId` dependency.
    ======================================================================

    EVENT CONTRACT:
    - 'qbx_k9unit:server:requestRecall' () [client->server, THIS FILE] -- no
      arguments. Rate-limited per CALLER source
      (`Config.Recall.RequestCooldownMs`, NewCooldown-backed, pruned on
      player-drop). A genuine no-op (a plain informational notice, never an
      error) for a caller who isn't currently partnered with a K9, who IS
      themselves the K9-role party of their own partnership, whose K9
      partner isn't currently online, or whose K9 partner has no active
      engagement right now -- none of those are error conditions, they're
      just "nothing to recall."
    ======================================================================
]]

if not Config.Features.Recall then return end

--- Sends an ox_lib notification to a specific player. Duplicated (not
--- shared) per this resource's own established convention for this tiny,
--- generic UI-plumbing helper -- see server/combat.lua's/
--- server/partnership.lua's own identical copies and comments.
--- @param target number
--- @param description string
--- @param notifyType string?
local function NotifyPlayer(target, description, notifyType)
    TriggerClientEvent('ox_lib:notify', target, {
        title = 'K9 Unit',
        description = description,
        type = notifyType or 'inform',
    })
end

-- Rate-limits the CALLER (the handler issuing Recall), never the K9 being
-- recalled -- a spam-prevention measure only, never a barrier to a
-- legitimate first request (see this file's header "NO UNBOUNDED TRAP"
-- section: this is the ONLY throttle on the way out, and it is deliberately
-- generous -- see config.lua's own comment on `Config.Recall.RequestCooldownMs`
-- for the exact value). NewCooldown-backed per REFACTOR_ROADMAP.md item 1's
-- own standing convention for this resource (never a hand-rolled cooldown
-- table) -- pruned on player-drop since this is keyed by player source.
-- DEFENSIVE READ, not a style preference: this runs at FILE-LOAD time, so a
-- missing Config.Recall table would take the whole resource down at server
-- start rather than degrading -- and it would do so only for the operator who
-- flipped Config.Features.Recall on without adding the config block, i.e. at
-- the worst possible moment. server/tenure.lua already guards its equivalent
-- read this way; this file did not, and that inconsistency was the finding.
-- The fallback matches config.lua's own shipped default, so a server missing
-- the block gets a working recall rather than a boot loop -- correct for a
-- TERMINATION path, where failing closed would mean nobody can call their dog
-- off.
local RECALL_COOLDOWN_FALLBACK_MS = 2000
local recallCfg = Config.Recall
local recallCooldownMs = (type(recallCfg) == 'table' and type(recallCfg.RequestCooldownMs) == 'number'
    and recallCfg.RequestCooldownMs) or RECALL_COOLDOWN_FALLBACK_MS
if type(recallCfg) ~= 'table' then
    print(('[qbx_k9unit] Config.Recall is missing; Recall is using a built-in %dms cooldown. Add the Config.Recall block from config.lua.'):format(RECALL_COOLDOWN_FALLBACK_MS))
end

local RecallCooldown = NewCooldown(recallCooldownMs)
RecallCooldown.RegisterPlayerDropped()

--- Step 1 (and only step -- Recall is a single, atomic, unconditional
--- action, not a consent handshake): a handler asks to call their own
--- partner K9 off whatever it is currently engaged with. See this file's
--- header "NO UNBOUNDED TRAP" section for why NONE of the checks below are
--- HasK9Access/CanShowK9UI on either party -- the only authorization this
--- handler applies is "is the caller genuinely this K9's established
--- partner," resolved entirely server-side.
RegisterNetEvent('qbx_k9unit:server:requestRecall', function()
    local src = source

    if not RecallCooldown.Consume(src) then
        return -- silent no-op: rate-limited, not an error worth notifying about (matches this resource's bark/leash-request/certify-action convention)
    end

    local Player = exports.qbx_core:GetPlayer(src)
    local citizenid = Player and Player.PlayerData and Player.PlayerData.citizenid
    if not citizenid then return end -- defensive: src disconnected between the event firing and this line, or not yet loaded

    -- Runtime existence guard, not a load-order assumption -- see this
    -- file's own FILE-TO-FILE CONTRACT above.
    if type(GetActivePartnerCitizenId) ~= 'function' then
        NotifyPlayer(src, 'Handler partnership is not available on this server.', 'error')
        return
    end

    -- `callerIsK9 == true` means `src` IS the K9-role party of their own
    -- partnership -- Recall is a PARTNER-issued action (see this file's
    -- header "CONCRETE BEHAVIOR"), so a K9 calling this on themselves is
    -- rejected: they already have their own self-release controls
    -- (releaseBiteHold/releaseDrag, server/combat.lua), which -- like this
    -- event -- never gate on HasK9Access either.
    local k9Citizenid, callerIsK9 = GetActivePartnerCitizenId(citizenid)
    if not k9Citizenid or callerIsK9 == true then
        NotifyPlayer(src, 'You are not currently partnered with a K9 to recall.', 'error')
        return
    end

    -- server/partnership.lua's own "FUTURE CONSUMERS" instruction: "the
    -- caller is still responsible for separately checking the resolved K9
    -- citizenid is CURRENTLY ONLINE... before notifying." Same
    -- exports.qbx_core:GetPlayerByCitizenId confidence note already
    -- disclosed in server/certifications.lua/server/partnership.lua/
    -- server/defense.lua -- not re-derived, reused with the same caveat.
    local k9Player = exports.qbx_core:GetPlayerByCitizenId(k9Citizenid)
    local k9Src = k9Player and k9Player.PlayerData and k9Player.PlayerData.source
    if not k9Src then
        NotifyPlayer(src, 'Your K9 partner is not currently online.', 'inform')
        return
    end

    -- Runtime existence guard, not a load-order assumption -- see this
    -- file's own FILE-TO-FILE CONTRACT above. server/combat.lua may be
    -- absent on a server that never enabled any Config.Features.BiteAndHold/
    -- NonLethalTakedown/PropDragging flag at all, in which case there is
    -- nothing for Recall to ever end anyway.
    if type(EndActiveEffectForHolder) ~= 'function' then
        NotifyPlayer(src, 'Your K9 is not currently engaged with a target.', 'inform')
        return
    end

    local ended = EndActiveEffectForHolder(k9Src)
    if not ended then
        NotifyPlayer(src, 'Your K9 is not currently engaged with a target.', 'inform')
        return
    end

    NotifyPlayer(src, 'Recall issued -- your K9 has been called back.', 'success')
    NotifyPlayer(k9Src, 'You have been recalled by your handler.', 'inform')
end)
