--[[
    qbx_k9unit/server/notify.lua

    REFACTOR_ROADMAP.md's "NEW, unrecorded: NotifyPlayer -- 12 independent
    copies, not the '2, closed' Revision 2 recorded" finding. Re-verified by
    direct grep before writing this file, NOT taken on the roadmap's word
    alone: 12 independent `local function NotifyPlayer(...)` definitions,
    each with its own `TriggerClientEvent('ox_lib:notify', ...)` body, were
    found in server/main.lua, server/certifications.lua, server/kennel.lua,
    server/medkit.lua, server/wellbeing.lua, server/combat.lua,
    server/partnership.lua, server/tenure.lua, server/admin.lua,
    server/recall.lua, server/propattachment.lua, and server/bonetool.lua.
    All 12 are now deleted (or, for the two files that deliberately vary the
    notification title -- see "TWO CALL SITES DELIBERATELY KEPT AS LOCAL
    WRAPPERS" below -- reduced to a one-line delegation to this file's
    single implementation).

    WHY A NEW FILE, NOT FOLDED INTO server/entities.lua (the roadmap's own
    suggested location) OR server/cooldowns.lua: both of those files'
    headers state, and justify at length, this resource's actual established
    convention -- a shared file is scoped to ONE responsibility, specifically
    so it does not become an everything-file as later passes add more call
    sites (server/cooldowns.lua's header: "a shared file should be scoped to
    ONE responsibility"; server/entities.lua's header applies that same rule
    to justify its OWN split from cooldowns.lua: "does this client-claimed
    netId actually resolve to something real is a genuinely different
    responsibility than a cooldown/mutex timer"). By that same test, "should
    this UI toast go out, and with what title" is a third, genuinely
    different responsibility from both "timing/mutex state" and "resolve a
    client-claimed reference defensively" -- it has nothing to do with
    entity resolution, reads no entity/network state at all, and every
    consumer needs it independently of whether it also happens to call
    ResolveNetworkEntity. The roadmap's own suggestion to bundle it into
    server/entities.lua was written as a quick "opportunistic, bundle into
    whatever pass next touches server/entities.lua" aside, not a considered
    application of the very rule that file's own header uses to justify its
    own existence -- applying that rule consistently here means a new file,
    not a third concern grafted onto entities.lua.

    Loaded in fxmanifest.lua's server_scripts alongside server/cooldowns.lua
    and server/entities.lua (see this repo's fxmanifest.lua owner for exact
    placement -- this file's own header does not edit that manifest, see
    the accompanying report). Unlike server/cooldowns.lua's constructors
    (called by their consumers at FILE-LOAD time), NotifyPlayer below is,
    same as server/entities.lua's ResolveNetworkEntity, only ever called at
    RUN time from inside an event/callback/command handler -- every one of
    the 12 original copies' call sites confirmed by direct read before this
    extraction. That means this file's exact position relative to its
    consumers is not load-bearing the same way cooldowns.lua's is (by the
    time any consumer's handler can actually fire, every server_scripts file
    has already finished loading, regardless of manifest order -- the same
    reasoning fxmanifest.lua's own comments already give for several other
    soft cross-file dependencies), but it is still placed early, alongside
    cooldowns.lua/entities.lua, to read in the same "shared primitive first"
    order those two already established, and so no runtime existence guard
    (`type(NotifyPlayer) == 'function'`) is needed at any call site -- this
    resource's own convention (see fxmanifest.lua's comments on
    server/medkit.lua's RestoreInjury reuse, etc.) reserves that guard for a
    genuine FORWARD reference (a file loaded earlier calling into a global
    defined by a file loaded later); every one of this file's consumers is
    loaded after it, exactly like every existing ResolveNetworkEntity call
    site.

    ======================================================================
    FILE-TO-FILE CONTRACT:
    - THIS FILE exposes ONE resource-global (no `local`) function:
        NotifyPlayer(target: number, description: string, notifyType: string?, title: string?)
      Sends a single ox_lib `ox_lib:notify` client event to `target`.
      `notifyType` defaults to `'inform'` and `title` defaults to `'K9 Unit'`
      -- both defaults exactly match what 9 of the 12 original copies
      hard-coded (server/main.lua, server/certifications.lua,
      server/kennel.lua, server/medkit.lua, server/wellbeing.lua,
      server/combat.lua, server/partnership.lua, server/recall.lua,
      server/propattachment.lua), so every one of those 9 files' call sites
      needed ZERO changes beyond deleting their own local copy of this
      function -- the shared signature is a strict superset of theirs.
      server/tenure.lua's copy was narrower still (`function
      NotifyPlayer(target, description)`, no `notifyType` parameter at
      all, always `'inform'`) -- also migrated for free: its call sites
      only ever passed 2 arguments, which produces the identical
      `type = 'inform', title = 'K9 Unit'` payload through this shared
      function's own defaults. Re-confirmed directly against both of
      server/tenure.lua's actual call sites before deleting its local copy,
      not assumed from the roadmap's summary alone.

    TWO CALL SITES DELIBERATELY KEPT AS LOCAL WRAPPERS, NOT FLATTENED:
    server/admin.lua (title `'K9 Unit — Admin Audit'`) and
    server/bonetool.lua (title `'K9 Unit — Bone Tool'`) each intentionally
    vary the notification title from the common `'K9 Unit'` default --
    confirmed as a deliberate per-subsystem choice, not an accident (each
    file's own prior comment on this function said so explicitly). Rather
    than either (a) collapsing both onto the generic title -- a real,
    player-visible regression this task was explicitly warned against -- or
    (b) appending the literal title string as a 4th argument at every one of
    admin.lua's 11 and bonetool.lua's 3 call sites (which would REPLACE one
    duplicated function body with the SAME title string duplicated 11/3
    times instead, a lateral move at best), each of those two files keeps
    its own tiny local `NotifyPlayer(target, description, notifyType)`
    function -- same name, deliberately shadowing this file's global inside
    that one file -- whose ENTIRE body is now a single delegating call to
    `_G.NotifyPlayer(target, description, notifyType, '<that file's own
    title>')`. The explicit `_G.` prefix is required, not decorative: inside
    a `local function NotifyPlayer(...)` body, a bare `NotifyPlayer(...)`
    call would resolve to the enclosing local itself (Lua's `local function
    f` is sugar for `local f; f = function() ... end`, so `f` is already in
    scope inside its own body) and recurse forever rather than reaching this
    file's global. This keeps each of those two files' every existing call
    site byte-for-byte unchanged (no 11-line/3-line mechanical edit, lower
    merge-conflict risk on two files this pass was told other agents are
    concurrently touching) while still moving the ACTUAL notification-
    sending logic (the `TriggerClientEvent('ox_lib:notify', ...)` table
    construction) to this single shared implementation -- the duplicated
    logic this task cared about consolidating. Only the one-line title
    string stays local to each file, which is exactly where a genuine
    per-subsystem difference belongs.
    ======================================================================
]]

--- Sends an ox_lib notification to a specific player. Single shared
--- implementation of the pattern 12 independent local copies hand-rolled
--- across this resource's server files -- see this file's header for the
--- full extraction writeup, including the two files that keep a thin local
--- wrapper to preserve their own deliberately different title.
--- @param target number
--- @param description string
--- @param notifyType string? -- defaults to 'inform', matching every original copy's own default
--- @param title string? -- defaults to 'K9 Unit', matching 9 of the 12 original copies' hard-coded title
function NotifyPlayer(target, description, notifyType, title)
    TriggerClientEvent('ox_lib:notify', target, {
        title = title or 'K9 Unit',
        description = description,
        type = notifyType or 'inform',
    })
end
