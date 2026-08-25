--[[
    qbx_k9unit/shared/compat/ambulance.lua

    K9Compat 'ambulance' adapters. Read shared/compat/core.lua's header AND
    DEVELOPER_REFERENCE.md §21 FIRST -- this file only implements the
    per-resource `factory(realm) -> table | nil` bodies core.lua's generic
    engine calls; it invents no new contract of its own.

    ======================================================================
    `IsDowned(src) -> true | false | nil` -- THE THREE-VALUED CONTRACT.

    `true`  -- this adapter's underlying resource says `src` is CONFIRMED
              down/dead/in-laststand right now.
    `false` -- this adapter's underlying resource says `src` is CONFIRMED
              NOT down right now (a real, positive "alive and up" signal
              from that resource -- not merely "we didn't find a reason to
              say yes").
    `nil`   -- UNKNOWN. This adapter could not get an answer: the resource
              is not `'started'`, the connected player could not be
              resolved, the underlying signal was never written for this
              session (e.g. a player who has not yet triggered a single
              death/laststand state change since login, so the field this
              adapter reads has literally never been set), or the call
              itself threw.

    `nil` IS A DISTINCT THIRD ANSWER, NOT A SYNONYM FOR `false` -- this is
    the single most important property of this file, called out explicitly
    in the task this file was built under, and worth restating here rather
    than only in a commit message: a caller that treats `nil` as `false`
    ("not down" by default) would let a K9 bite/drag/take down someone this
    adapter genuinely could not vouch for either way, which is exactly
    backwards from this resource's own fail-closed convention for every
    other ambiguous safety signal (see server/combat.lua's/
    server/defense.lua's own `IsPlayerDownedOverride` handling: an override
    that ERRORS is treated as "NOT down" specifically because THAT
    function's own contract is a plain boolean with no room for "unknown" --
    this file's contract is deliberately richer, and a caller consuming it
    must preserve that richness, not flatten it back down to a boolean at
    the call site). A caller that cannot use a three-valued answer should
    treat `nil` the same way it already treats "no override configured
    at all" -- fall through to whatever OTHER signal it already has (see
    PRECEDENCE below), never coerce `nil` into a specific boolean itself.

    ======================================================================
    PRECEDENCE -- `Config.Combat.PropDragging.IsPlayerDownedOverride` KEEPS
    WINNING, UNCONDITIONALLY. THIS FILE DOES NOT TOUCH THAT.

    server/combat.lua's `IsTargetDowned` and server/defense.lua's
    `IsHandlerDown` are this session's own DO-NOT-EDIT list (per the task
    that produced this file) -- and even without that restriction, this
    file would not touch them: `Config.Compat`'s own comment (config.lua,
    directly above the `ambulance` candidates block) makes an explicit
    promise to an operator who already wrote an `IsPlayerDownedOverride`:
    "That hook was the original answer to this problem and is not being
    retired -- if you already wrote one, it keeps working exactly as
    before." This file is built so that promise is trivially kept BY
    CONSTRUCTION, not by convention: neither `server/combat.lua` nor
    `server/defense.lua` calls anything in `K9Compat` today, at all -- so
    an operator's existing override is, right now, the ONLY thing either
    file ever consults for this question, exactly as it was before this
    file existed. Nothing here changes that.

    THE FOLLOW-UP THIS FILE ENABLES BUT DOES NOT PERFORM: if a future pass
    over `server/combat.lua`/`server/defense.lua` wants to consult this
    adapter as a FALLBACK (never a replacement) for their own best-effort
    `metadata.isdead`/`metadata.inlaststand` default -- the one their own
    header comments already disclose as "a CLIENT-self-reported flag ...
    not a server-verified state machine" -- the resolution order that
    follow-up MUST use, to keep the existing promise intact, is:

        1. `Config.Combat.PropDragging.IsPlayerDownedOverride`, if it is a
           function -- call it, exactly as today. Its answer wins,
           unconditionally, whatever this file would have said.
        2. ONLY if that override is `nil` (not configured at all): consult
           `K9Compat.Get('ambulance').IsDowned(src)`. Treat its `true` as
           "downed," its `false` as "not downed," and its `nil` (UNKNOWN)
           by falling through to step 3 -- NEVER by treating `nil` as
           either boolean.
        3. The existing `metadata.isdead == true or metadata.inlaststand
           == true` best-effort guess, exactly as today, as the final
           fallback.

    This ordering is documented here, in the adapter file, rather than
    silently assumed by whoever writes that follow-up, precisely because
    getting steps 1 and 2 swapped would silently break the "your override
    keeps winning" promise for every operator who already relies on it.
    This file's own registration message to the team (see this pass's
    hand-off) flags this exact follow-up to whoever owns those two files
    next, rather than this pass quietly assuming it will happen correctly
    on its own.

    ======================================================================
    SECURITY: `IsDowned` NEVER GRANTS PERMISSION -- CONFIRMED, HERE'S HOW.

    Nothing in this file, or reachable through it, performs or influences
    any rank/certification/ownership/XP decision (matches core.lua's own
    resource-wide SECURITY guarantee). Concretely, for THIS specific
    method: the ONLY thing PRECEDENCE above allows a future caller to do
    with a `true`/`false`/`nil` from this file is decide whether one
    specific mechanic (bite-hold / takedown / prop-drag) refuses to engage
    a target that already looks incapacitated -- refusing an action is the
    single, narrow effect in play. A HOSTILE answer from a broken or
    malicious third-party ambulance resource has exactly two possible
    directions, both bounded, matching this file's own documented contract
    for its `true`/`false`/`nil` values:
      - a false `true` (claims someone is down who isn't) makes a mechanic
        REFUSE to fire on a target it otherwise could have -- the target is
        never worse off, and the caller loses nothing they are entitled to
        that a legitimate ambulance resource wouldn't also have blocked for
        a genuinely downed target.
      - a false `false` or `nil` (claims someone is NOT down, or claims not
        to know, when they actually are) at WORST reproduces this
        resource's own pre-existing best-effort-guess behaviour (step 3 of
        PRECEDENCE above) -- a target this resource could ALREADY be wrong
        about today, with no new capability added by this file's
        existence.
    In neither direction does an adapter's answer make a player a K9, mint
    XP, bypass a rank, or grant ownership of anything -- there is no code
    path from "an ambulance adapter returned X" to any of those outcomes
    anywhere in this resource, and this file adds none.

    ======================================================================
    RESEARCH METHODOLOGY AND HONEST CONFIDENCE GRADING.

    Every CONFIRMED adapter below cites the exact primary source read this
    session (a resource's own server-side `.lua` source file, fetched
    directly from that resource's own public GitHub repository). Every
    UNCONFIRMED adapter is REGISTERED ANYWAY with a factory that
    unconditionally returns `nil` for every realm -- see shared/compat/
    dispatch.lua's own header for the full reasoning on why "registered but
    always nil" beats "not registered at all" (a specific, actionable
    `/k9compat` skip reason, and a single obvious anchor for whoever next
    confirms the real signal). Per-resource verdicts, in
    `Config.Compat.Systems.ambulance.candidates` order:

      qbx_medical (CONFIRMED). Primary source:
      https://raw.githubusercontent.com/Qbox-project/qbx_medical/main/server/main.lua
      (fetched this session; repo/branch confirmed live via a real
      fxmanifest.lua fetch at the same URL root). `getDeathState` there
      reads `player.PlayerData.metadata.isdead` /
      `.inlaststand` directly, and the file's own `AddStateBagChangeHandler`
      on its `DEATH_STATE_STATE_BAG` is what WRITES those two fields
      server-side (`player.Functions.SetMetaData('isdead', ...)` /
      `('inlaststand', ...)`) in response to that state bag changing.
      Tracing the state bag's origin (client/dead.lua's own
      `SetDeathState` call, client-owned `LocalPlayer.state`) confirms this
      is the SAME "client-self-reported flag, not a server-verified state
      machine" caveat server/combat.lua's/server/defense.lua's own header
      comments already disclose for their existing best-effort default --
      this adapter reads the identical two metadata fields, at the
      identical trust level, and its only real improvement over that
      existing default is CONFIRMING qbx_medical is actually the resource
      writing them (via `GetResourceState`) before trusting the read at
      all, rather than guessing at the fields with no such confirmation.

      qb-ambulancejob (CONFIRMED). Primary source:
      https://raw.githubusercontent.com/qbcore-framework/qb-ambulancejob/main/server/main.lua
      (fetched this session; repo/branch confirmed live via a real
      fxmanifest.lua fetch at the same URL root). `RegisterNetEvent(
      'hospital:server:SetDeathStatus', function(isDead) ... Player.
      SetMetaData('isdead', isDead) ... end)` and a second handler writing
      `SetMetaData('inlaststand', bool)` a few lines later -- the SAME two
      metadata field names as qbx_medical above, written the same
      client-triggered way. This adapter's body is therefore identical in
      shape to qbx_medical's, differing only in which resource name gates
      it.

      ps-ambulancejob (UNCONFIRMED). Searched forum.cfx.re for the exact
      strings "ps-ambulancejob" and "ps-ambulance" -- ZERO results, across
      every query tried this session, which is itself the finding worth
      recording: unlike every other candidate in either adapter file (each
      of which returned at least some forum discussion, even the ones this
      pass could not find source for), this exact resource name produced
      no corroborating evidence of being a real, in-use FiveM resource at
      all in the sources this session could reach -- not merely "closed
      source," but genuinely unconfirmed to exist as commonly understood.
      Registered as UNCONFIRMED rather than omitted regardless, in case a
      real, low-visibility resource by this exact name does exist on some
      server this pack runs on -- `/k9compat` will still show a specific,
      honest reason if it's ever detected as started.

      wasabi_ambulance (UNCONFIRMED). The publisher's GitHub organisation
      IS real and reachable (`WasabiRobby`, confirmed via
      `raw.githubusercontent.com/WasabiRobby/wasabi_tireslash/...`, a
      sibling resource from the same publisher, cited in forum.cfx.re
      topic 4827208) -- but no `wasabi_ambulance` repository resolved under
      that same organisation, and a forum.cfx.re full-text search across
      dozens of threads that mention `wasabi_ambulance` by name (bug
      reports, integration questions, comparison threads) found not one
      that links to a public source repository for it. Consistent with
      wasabi_ambulance being closed-source/store-distributed like several
      other Wasabi-branded resources appear to be, but -- same discipline
      as every other UNCONFIRMED entry in this file -- that is an
      inference, not a confirmation, so no signature is guessed.

      esx_ambulancejob (UNCONFIRMED, WORTH ITS OWN NOTE -- this one very
      nearly resolved). FOUR independent forum.cfx.re threads (topics
      4859039, 3772335, 4855036 -- the last one linking a SPECIFIC file,
      line-ranged: `.../esx-legacy/blob/main/%5Besx_addons%5D/
      esx_ambulancejob/client/main.lua#L16-L35` -- and 4731507) all cite
      the SAME repository, `esx-framework/esx-legacy`, with
      `esx_ambulancejob` living as a subfolder of that monorepo (ESX's
      current consolidated-repo convention, one folder per legacy addon,
      rather than one repository per resource the way qb-ambulancejob is
      laid out). Despite four independent citations agreeing on the exact
      path, EVERY `raw.githubusercontent.com` fetch against
      `esx-framework/esx-legacy` this session -- the repository root
      README, the cited subfolder's `fxmanifest.lua`, even the exact
      line-ranged file one of those four threads links directly -- returned
      HTTP 404, on both a `main` and `master` branch guess. `api.github.com`
      access to the same repository was separately denied by this session's
      own network policy ("GitHub access to this repository is not enabled
      for this session"), which is a DIFFERENT failure mode than a genuine
      absent/renamed repository would produce and could not be resolved
      within this pass. Left UNCONFIRMED rather than trusting four
      forum citations of a path this session could not itself fetch even
      once -- this file's own standard is a primary source THIS SESSION
      READ, not secondhand agreement, however consistent.
    ======================================================================

    RACE WINDOW / TWO-STEP EXPORT SHAPE: identical reasoning to
    shared/compat/dispatch.lua's own header -- read that file's "RACE
    WINDOW" section once, it applies here unchanged. Both CONFIRMED
    adapters below re-check `GetResourceState` at call time (not merely at
    detection time) before touching `exports.qbx_core`, and every
    `exports.qbx_core` access AND call goes through its own `pcall`,
    matching server/tracking.lua:772-810's two-step shape.

    A NOTE ON `exports.qbx_core` ITSELF, SPECIFICALLY: unlike
    `ps-dispatch`/`qbx_medical`/etc. (genuinely optional soft dependencies
    this file gates on `GetResourceState`), `qbx_core` is this resource's
    OWN hard `fxmanifest.lua` dependency -- server/combat.lua's/
    server/defense.lua's own existing `exports.qbx_core:GetPlayer(...)`
    calls carry no runtime existence guard at all, for that exact reason
    (see server/integrations.lua's header for the identical "always
    present, loaded well before this file" reasoning applied to a
    different same-resource dependency). This file follows that same
    established convention for `qbx_core` specifically -- the `pcall`
    around it below is defence against a THROW (a disconnected/invalid
    `src`, which `GetPlayer` is documented to return `nil` for but this
    file does not take that documentation on faith either), not against
    the resource being absent.
]]

-- ======================================================================
-- qbx_medical -- CONFIRMED. See header for the exact source cited.
-- ======================================================================
K9Compat.RegisterAdapter('ambulance', 'qbx_medical', function(realm)
    -- ambulance.client requires nothing (K9Compat.RequiredMethods.
    -- ambulance.client == {}) and this adapter has nothing to offer the
    -- client VM anyway (metadata is a server-side qbx_core concept) --
    -- `nil` is the honest answer for that realm.
    if realm ~= 'server' then return nil end

    return {
        --- @param src number
        --- @return boolean|nil downed -- true/false/nil, see header
        IsDowned = function(src)
            if GetResourceState('qbx_medical') ~= 'started' then return nil end

            local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
            if not ok or type(player) ~= 'table' then return nil end

            local metadata = player.PlayerData and player.PlayerData.metadata
            if type(metadata) ~= 'table' then return nil end

            if metadata.isdead == true or metadata.inlaststand == true then
                return true
            end
            if metadata.isdead == false then
                -- A real, positive "confirmed alive" signal -- qbx_medical
                -- itself wrote this value (see header CONFIRMED note), it
                -- is not merely "we found no reason to say yes."
                return false
            end
            -- Neither field is a recognised boolean yet (e.g. a player who
            -- has never triggered a single death/laststand transition this
            -- session, so qbx_medical's own AddStateBagChangeHandler has
            -- never fired for them) -- genuinely UNKNOWN, not "alive."
            return nil
        end,
    }
end)

-- ======================================================================
-- qb-ambulancejob -- CONFIRMED. See header for the exact source cited.
-- Identical body to qbx_medical above -- see header for why (same two
-- metadata field names, same client-triggered write path).
-- ======================================================================
K9Compat.RegisterAdapter('ambulance', 'qb-ambulancejob', function(realm)
    if realm ~= 'server' then return nil end

    return {
        --- @param src number
        --- @return boolean|nil downed -- true/false/nil, see header
        IsDowned = function(src)
            if GetResourceState('qb-ambulancejob') ~= 'started' then return nil end

            local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
            if not ok or type(player) ~= 'table' then return nil end

            local metadata = player.PlayerData and player.PlayerData.metadata
            if type(metadata) ~= 'table' then return nil end

            if metadata.isdead == true or metadata.inlaststand == true then
                return true
            end
            if metadata.isdead == false then
                return false
            end
            return nil
        end,
    }
end)

-- ======================================================================
-- ps-ambulancejob -- UNCONFIRMED. See header RESEARCH METHODOLOGY. DO NOT
-- replace this `nil` with a guessed metadata field or export name -- see
-- shared/compat/dispatch.lua's header for why a guessed signature is worse
-- than no adapter at all.
-- ======================================================================
K9Compat.RegisterAdapter('ambulance', 'ps-ambulancejob', function(_realm)
    return nil
end)

-- ======================================================================
-- wasabi_ambulance -- UNCONFIRMED. Same reasoning and same instruction as
-- ps-ambulancejob immediately above.
-- ======================================================================
K9Compat.RegisterAdapter('ambulance', 'wasabi_ambulance', function(_realm)
    return nil
end)

-- ======================================================================
-- esx_ambulancejob -- UNCONFIRMED. See header RESEARCH METHODOLOGY --
-- this one had four independent, mutually-consistent secondhand citations
-- and still stays UNCONFIRMED, on purpose, because none of them could be
-- verified by actually reading the source this session. Same
-- do-not-guess instruction as ps-ambulancejob above.
-- ======================================================================
K9Compat.RegisterAdapter('ambulance', 'esx_ambulancejob', function(_realm)
    return nil
end)
