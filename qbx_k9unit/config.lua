--[[
    qbx_k9unit/config.lua

    Transcribed verbatim from DEVELOPER_REFERENCE.md §5 ("Config schema (concrete shape)"),
    which is unchanged by the post-draft correction (§1/§2/§4.4/§4.5) — no
    additions or removals beyond what's noted inline below. If DEVELOPER_REFERENCE.md §5
    is revised again, re-diff this file against it before trusting it as
    still in sync.

    HISTORY: an earlier draft of this file added a Config.K9DespawnGraceSeconds
    field for a handler->K9 spawn-registry grace timer. That concept was
    removed entirely once DEVELOPER_REFERENCE.md's post-draft correction established the
    K9 is a player's own persistent character with no spawn/despawn/registry
    at all (see the NOTE further down where that field used to live).
]]

Config = {}

-- ======================================================================
-- FEATURE TOGGLES — every leaf feature independently switchable.
-- The code must gate on these at the point of activation, not just declare
-- them (see §3 acceptance criteria).
-- ======================================================================
-- WHAT IS IN THIS FILE  --  a map, so you can stop scrolling.
--
-- This file is long. It is deliberately ONE file rather than several,
-- because hunting through five config files is worse than scrolling
-- through one. What it was missing is an index. This is it.
--
-- HOW TO USE IT: find the thing you want below, then search this file for
-- the name in `backticks`. No line numbers here on purpose -- they go stale
-- the moment anything is added, and a wrong line number is worse than none.
--
-- ONE TRAP WORTH KNOWING BEFORE YOU EDIT ANYTHING: every field in this
-- file whose name ends in `CooldownMs`. In most FiveM scripts, setting a
-- cooldown to 0 means "no cooldown". **HERE IT DOES NOT.** This resource's
-- cooldown system fails CLOSED on zero or a negative number, which would
-- block the action permanently rather than allow it freely -- the exact
-- opposite of what you would expect.
--
-- You will not break anything by trying: a bad value is now caught at
-- startup, quietly swapped for a sensible built-in number, and a warning
-- naming the exact setting is printed to your server console. But it will
-- never do what "0 = off" does elsewhere.
--
-- There is no value that disables a cooldown. If you genuinely want a
-- mechanic to have none, that is not a cooldown setting -- turn the whole
-- feature off in `Config.Features` instead, or set the cooldown to
-- something very small like 1.
--
-- THE ONE TO KNOW ABOUT: `Config.Features` is the master list of on/off
-- switches, right below this. Almost every entry there has its own settings
-- table further down with the same name -- turn something on there, then
-- search for its name to tune it.
--
-- WHO CAN DO WHAT
--   Config.Departments .............. which jobs count as police, and the
--                                     rank numbers that unlock things
--   Config.HighCommand .............. the senior rank that outranks every
--                                     other check here
--   Config.Permissions .............. the four things high command can hand
--                                     to one person
--   Config.FeatureControl ........... which features need a personal grant
--                                     before someone can use them
--   Config.CommandTablet ............ the K9 tablet: item, command, or both
--
-- BECOMING AND BEING A K9
--   Config.Peds ..................... which models can be a K9. ANY model
--                                     works -- it does not have to be a dog
--   Config.K9Appearance ............. what happens to someone's character
--                                     when they are made a K9
--   Config.CertificationTiers ....... trainee / certified / senior, and how
--                                     to add more
--   Config.K9Specializations ........ narcotics, explosives, patrol
--   Config.AllowSelfCertification ... whether an officer may certify
--                                     themselves
--   Config.CertifyProximityMeters ... how close you must stand to certify
--   Config.CertificationExpiry* ..... whether certifications lapse, and the
--                                     warning before they do
--
-- EARNING AND RANKING UP
--   Config.XP ....................... what each action pays (the K9)
--   Config.XPTiers .................. the four K9 ranks and what they unlock
--   Config.HandlerXP ................ what each HANDLER action pays -- a
--                                     separate total from Config.XP, above
--   Config.HandlerXPTiers ........... the handler ranks and what they unlock
--   Config.Leaderboard .............. the /k9stats table
--
-- THE JOB ITSELF
--   Config.Tracking ................. scent, blood and gunpowder trails
--   Config.WaterTrackingDecay ....... trails going cold in water
--   Config.SearchZones .............. searching vehicles and people
--   Config.SearchContrabandItems .... what counts as a find
--   Config.ContrabandAlertTiers ..... how big a find has to be to matter
--   Config.FindAlerts ............... the dog sitting and barking on a find
--   Config.Combat ................... bite and hold, takedowns, dragging
--   Config.PursuitSprint ............ the short burst of real speed
--   Config.Recall ................... calling the dog off
--   Config.Partnership .............. handler and K9 pairing
--   Config.DoorInteraction .......... scratching at doors
--   Config.Vision ................... thermal and night vision
--
-- KIT AND PLACES
--   Config.K9Vehicles ............... which vehicles a K9 can ride in
--   Config.VehicleInteractMeters .... how close to stand to load up
--   Config.LeashMaxDistance ......... how far the leash stretches
--   Config.K9Inventory .............. the dog's own storage
--   Config.K9Medkit ................. patching the dog up
--   Config.K9EquipmentShop .......... the supply shop and its shop dogs
--   Config.DeployableKennel ......... putting down a portable kennel
--   Config.PropAttachments .......... vests and gear on the dog
--   Config.FetchMechanic ............ fetch
--
-- TRAINING AND PLAY
--   Config.TrainingZones ............ where the practice yards are
--   Config.Training ................. how the practice drills behave
--   Config.ScentTrailHunt ........... follow-your-nose hunts
--   Config.ScentLineup .............. sniff the row and pick the match
--   Config.SARCalls ................. missing-person and rescue calls
--
-- LOOK, SOUND AND FEEL
--   Config.Wellbeing ................ tiredness, mood, fear, injury
--   Config.AdvancedBarkRadial ....... the bark menu
--   Config.ProximityAudioFX ......... hearing the dog from a distance
--   Config.ContrabandScreenFX ....... the screen effect on a find
--
-- PLUMBING AND SAFETY
--   Config.Compat ................... auto-detecting which other scripts
--                                     your server runs
--   Config.Database ................. running with or without a database
--   Config.K9DownDispatch ........... announcing a K9 going down
--   Config.AdminAudit ............... the read-only audit commands
--   Config.BoneSweepTool ............ a developer-only tool; the flag ships
--                                     `true` but stays unreachable without an
--                                     operator-set convar -- see
--                                     Config.Features.BoneSweepDevTool
-- ======================================================================

-- ======================================================================
Config.Features = {
    -- Phase 1 (vertical slice)
    LeashMechanics       = true,
    RadialMenu           = true,
    VehicleEntryExit     = true,
    BasicBarkSounds      = true,
    AgilityBasicJump     = true,  -- native jump/crouch only, no fence-vault logic yet

    -- Phase 2 (tracking & vision)
    ScentTracking        = true,
    BloodTracking        = true,
    WaterTrackingDecay   = true,
    GunpowderSniffing    = true,

    -- client/tracking.lua + server/tracking.lua (owner-directed pass:
    -- "make scent tracking... a keybind that makes a colour dot appear
    -- where players['] blood etc have walked"). A K9 handler presses a
    -- keybind (RegisterKeyMapping, Config.Tracking.ScentVision.keybind) and
    -- sees a live overlay of ground-level coloured dots marking where
    -- OTHER connected players have recently walked -- each dot expires on
    -- its OWN individual timer from the moment it was recorded (never a
    -- whole-trail timer), so a trail visibly eats itself from the tail end
    -- while its fresh end keeps growing. Distinct from Track Scent/Blood/
    -- Gunpowder above (client/tracking.lua's existing Start*Track()
    -- trio): those resolve and walk toward exactly ONE nearest logged
    -- event (a damage hit, a gunshot, an item drop); this instead shows
    -- several people's general walked paths at once, colour-coded per
    -- person so multiple trails through the same area can be told apart.
    -- Server-authoritative throughout: the server samples every connected
    -- player's own position on its own timer (never a value the client
    -- supplies), and a querying K9's client is only ever handed the
    -- nearest HANDFUL of trails within range, pre-coloured, never raw
    -- identity and never the whole server's positions -- see
    -- Config.Tracking.ScentVision below and server/tracking.lua's own
    -- header for the full design (including why "handful", not
    -- "everyone", is also what keeps this cheap on a populated server).
    ScentVision          = true,

    SearchZones          = true,
    ContrabandAlerts     = true,

    -- server/findalert.lua + client/findalert.lua (PROJECT_HISTORY.md §1, "Make
    -- finds feel like a real alert, not a pop-up message"). A pure REACTION
    -- layer over the search outcome server/search.lua already computes --
    -- it adds no detection logic of its own. When a search comes back
    -- positive, the searching K9's own character automatically sits (a real
    -- detection dog's "trained final response") and barks. The text message
    -- you already get is unchanged; this is on top of it, not instead of it.
    FindAlerts           = true,

    -- client/scenttrail.lua + server/scenttrail.lua (PROJECT_HISTORY.md §2,
    -- "follow your nose"). Turns a search into a hunt: the K9 sets off
    -- after a hidden spot somewhere near them, guided ONLY by a growl that
    -- pulses faster as they get warmer. No marker, no blip, and -- this is
    -- the part that makes it honest -- the hiding place's coordinates are
    -- never sent to the player's game at all, only a distance. Nobody can
    -- read the answer out of their own client. Awards no XP.
    ScentTrailHunt       = true,

    -- client/pursuitsprint.lua + server/pursuitsprint.lua (PROJECT_HISTORY.md §5).
    -- A short burst where the dog is genuinely faster than the person it is
    -- chasing. Only usable against a WANTED target, only in short bursts,
    -- and on a cooldown -- it ends a foot chase, it does not remove them.
    PursuitSprint        = true,

    -- client/scentlineup.lua + server/scentlineup.lua (PROJECT_HISTORY.md §4).
    -- "Sniff the row and pick the match": several players stand in a line,
    -- the server secretly picks one, and the K9 gets ONE guess. Nobody --
    -- not even the K9 running it -- is told the answer until that guess is
    -- committed, so it cannot be read out of anyone's game. Awards no XP.
    ScentLineup          = true,

    -- client/sarcalls.lua + server/sarcalls.lua (PROJECT_HISTORY.md §3).
    -- Missing-person and search-and-rescue calls: the same hunting feel as
    -- the scent trail, pointed at a lost hiker or a piece of property
    -- instead of contraband. Nobody is arrested and nothing bad happens --
    -- it resolves as a rescue. The "missing person" is always a scenery
    -- NPC that appears only after the call is already solved, never a real
    -- player, so nobody can be dragged into one without agreeing.
    SARCalls             = true,
    ThermalVision        = true,
    NightVision          = true,
    DoorInteraction      = true, -- nudge-open / scratch-to-alert

    -- Phase 3 (combat & action)
    BiteAndHold          = true,
    NonLethalTakedown    = true,
    HandlerDownDefense   = true,
    PropDragging         = true,
    AgilityAdvanced      = true, -- fence/window vault approximation

    -- server/recall.lua + client/recall.lua (DEVELOPER_REFERENCE.md §12.5.1's
    -- "Recall actor"). The handler's escape hatch: ends whatever active
    -- effect their partnered K9 currently holds (bite/takedown/drag alike --
    -- deliberately generalised beyond §12.5.1's bite-only text, since
    -- narrowing it would leave a handler unable to call off a mid-drag K9,
    -- a strictly worse unbounded-trap posture). The TERMINATION path is
    -- never gated on HasK9Access/CanShowK9UI on either party, by design --
    -- a decertified handler must still be able to call their dog off.
    Recall               = true,

    -- DEVELOPER_REFERENCE.md §12.0 item 7 (Revision 5, coder-architect) /
    -- server/partnership.lua (coder-backend, this pass). Gates the
    -- mutually-consented "Partner Up" registry ONLY -- HandlerDownDefense
    -- and BiteAndHold's Recall actor (the two features this registry
    -- unblocks) are each independently gated by their OWN flags above.
    -- At the time this paragraph was written both of those remained
    -- unimplemented regardless of this flag's value; that is no longer
    -- true -- HandlerDownDefense (server/defense.lua) and Recall
    -- (server/recall.lua) are both implemented, and both flags ship `true`
    -- above, same as this one.
    -- DEFAULT ONCE DIVERGED FROM DEVELOPER_REFERENCE.md §12.0 item 7 point 5's
    -- OWN "recommended default true" text -- that was deliberate at the
    -- time, not an oversight: that recommendation predated any real code
    -- existing, and this resource's then-shipped convention for every
    -- other Phase 3 mechanic was that a newly-landed mechanic stays off by
    -- default until its own balance/security go-live review, independent
    -- of implementation completeness. This flag was directed to default
    -- `false` for exactly that reason. That go-live review has SINCE
    -- happened -- see server/partnership.lua's own header for what was
    -- independently verified -- and this flag now ships `true` above,
    -- consistent with BiteAndHold/NonLethalTakedown/PropDragging/
    -- HandlerDownDefense all having gone through the same review and now
    -- shipping `true` too.
    HandlerPartnership   = true,

    -- server/tenure.lua (DEVELOPER_REFERENCE.md Part B §7). Grants a one-time,
    -- flat XP bonus to the K9-role party when a partnership's CONTINUOUS
    -- tenure crosses a configured threshold -- the first gameplay
    -- consequence wired to the HandlerPartnership registry, which landed as
    -- a foundation with none. Has NO effect unless HandlerPartnership AND
    -- XPProgression are ALSO true (server/tenure.lua re-checks both at point
    -- of use). REQUIRES the k9_partnerships.tenure_bonus_tier_granted
    -- column -- present in sql/install.sql for fresh installs, and in
    -- sql/migrations/0003_*.sql for existing databases. Without that column
    -- the milestone bonus would re-grant on every restart; tenure.lua's
    -- queries are pcall-wrapped and degrade to a silent no-op until it
    -- exists, so an un-migrated database is inert rather than exploitable.
    PartnershipTenureBonus = true,

    -- Phase 4 (inventory, progression, vitality)
    K9Inventory          = true,
    XPProgression        = true,

    -- server/progression.lua's AwardHandlerXP/GetHandlerXPTier -- a SEPARATE
    -- accumulated total from XPProgression above (own `handler_xp` column
    -- on the existing k9_progression row, own Config.HandlerXPTiers ladder,
    -- own Config.HandlerXP.awards table) for actions a HUMAN HANDLER
    -- performs, as opposed to XPProgression's K9-mechanical actions
    -- (search/track/bite/takedown). See Config.HandlerXPTiers' own header
    -- for the full "why a second total, not the same one" reasoning.
    --
    -- CODE LANDED (this pass, coder-backend): AwardHandlerXP/GetHandlerXPTier
    -- now exist in server/progression.lua, K9Store.HandlerXP_Get/
    -- HandlerXP_UpsertAdd now exist in server/datastore.lua, this flag has
    -- its own FEATURE_TIERS entry (server/runtimecontrol.lua) and its own
    -- `block.HandlerXPProgression`/`feature.HandlerXPProgression`
    -- per-person path (server/progression.lua's
    -- IsHandlerXPProgressionPermittedForCitizenId, the identical four-step
    -- shape every other feature here already gets) -- so this key is back.
    --
    -- STILL DEFAULT FALSE, DELIBERATELY -- for a NARROWER reason than
    -- before this pass (the missing-code gap above is closed; a real
    -- anti-farm gap on two specific award keys is not). Of the six award
    -- keys in Config.HandlerXP.awards below, FOUR are wired this pass and
    -- each rides a real per-actor throttle of its own:
    -- `handlerCertifyK9` (server/certifications.lua's GrantCertification
    -- AND GrantCertificationOffline) is gated by that file's own
    -- CertifyXpMintCooldown -- a DEDICATED per-(granter, target) MINT
    -- cooldown (24 real hours) on the AWARD itself, added by the same
    -- economy audit (2026-08-26) that found and closed a live farm loop
    -- here. This bullet used to claim handlerCertifyK9 was "already gated
    -- by that file's own per-granter IsCertifyActionOnCooldown check" --
    -- THAT WAS FALSE, by this exact section's own standard:
    -- IsCertifyActionOnCooldown is a flat 1,500ms per-granter fat-finger
    -- guard on the grant/revoke ACTION (same shape as handlerTreatK9's
    -- MedkitCooldown and handlerKennelDeploy's DeployCooldown below,
    -- neither of which this comment ever credited as a mint guard), not a
    -- per-actor MINT cooldown -- and with Config.AllowSelfCertification
    -- true by default, an eligible certifier could `/k9certify <self>` then
    -- `/k9decertify <self>` on repeat, 3 seconds per cycle, 60,000 XP/hr
    -- gross -- worse than either of the two awards this comment already
    -- refused to wire below for exactly this class of gap. Corrected here
    -- and at server/certifications.lua's own CertifyXpMintCooldown
    -- declaration comment (search that file for "FALSIFIED CLAIM"), not
    -- just patched around. handlerCertifyK9 is genuinely safe to wire NOW,
    -- for the same reason this comment always intended: a first
    -- certification of a genuinely new person still pays every time, and a
    -- repeat mint against the SAME (granter, target) pair inside 24 hours
    -- does not -- see CertifyXpMintCooldown's own declaration comment for
    -- the full arithmetic. The three
    -- `handlerPartnershipTenure{1,7,30}Day` milestones (server/tenure.lua's
    -- CheckTenureMilestonesForK9, one-time-per-partnership-row, never
    -- repeating -- the SAME CAS guard the K9-side milestones already rely
    -- on) are unaffected by this correction. The remaining TWO --
    -- `handlerTreatK9` (server/medkit.lua) and
    -- `handlerKennelDeploy` (server/kennel.lua) -- are DELIBERATELY LEFT
    -- UNWIRED this pass: AwardHandlerXP is called from NOWHERE for either
    -- of those two actionKeys. Neither file has a per-actor XP MINT
    -- cooldown today -- server/medkit.lua's own MedkitCooldown is keyed by
    -- the TARGET K9's citizenid, not the USING handler's, and
    -- server/kennel.lua's own DeployCooldown throttles the ACTION, not a
    -- per-actor mint -- and the arithmetic below (unchanged, still
    -- accurate) shows exactly why minting through either unthrottled would
    -- be unsafe even with the shared budget backing it up. Concretely,
    -- WITHOUT a dedicated per-actor mint cooldown,
    -- Config.DeployableKennel.deployCooldownMs's own 5000ms default lets a
    -- SOLO handler mint handlerKennelDeploy's 8 XP every 5 seconds with no
    -- accomplice and no per-actor throttle at all -- 5,760 XP/hr
    -- uncapped, which alone would exhaust the ENTIRE shared 3,600 XP/hr
    -- budget (the same budget XPProgression's own K9 awards rely on to
    -- keep Elite over two hours away) in under 40 minutes. The shared
    -- budget still caps the damage (nobody can mint UNLIMITED XP), but it
    -- would make kennel-deploy-spam the fastest way to cap out a
    -- citizenid's TOTAL K9+handler XP for the hour, crowding out every
    -- legitimate award. Flip this to `true` only once a real per-actor mint
    -- cooldown has landed in server/medkit.lua AND server/kennel.lua AND
    -- each file's own success path actually calls AwardHandlerXP -- same
    -- "landed as a foundation, reviewed before go-live" posture
    -- Config.Features.HandlerPartnership itself went through above.
    HandlerXPProgression = false,

    HealthStaminaHUD     = true,
    FatigueSystem        = true,
    MoodSystem           = true,
    FearStressSystem     = true,
    DistractionSystem    = true,
    InjuryLimping        = true,
    K9Medkit             = true,
    ContrabandScreenFX   = true,

    -- server/admin.lua. A read-only, JOB-RANK-gated in-game audit surface
    -- over the three tables this resource already writes (k9_certifications,
    -- k9_partnerships, k9_search_log) -- five commands, nine hardcoded SQL
    -- templates, zero mutation paths of any kind. Replaces "documented raw
    -- SQL an admin runs by hand" (DEVELOPER_REFERENCE.md Part B item 2). This one
    -- exposes WHO SEARCHED WHOM, so it is a privacy boundary as well as a
    -- security one: set `auditGrade` on each Config.Departments entry below
    -- deliberately. There is no ACE permission to grant -- that gate was
    -- removed on 2026-08-25.
    AdminAuditCommands   = true,

    -- server/integrations.lua. Announces a K9 going down so YOUR dispatch
    -- can react to it. Read-only detection -- it fires a generic
    -- 'qbx_k9unit:events:k9Down' event and nothing more.
    -- Deliberately NOT tied to any particular dispatch resource: this
    -- resource never calls into a named third party, it announces a fact
    -- and anything listening can act on it. A server with no dispatch at
    -- all sees a clean no-op, no errors, no log spam. That is what makes it
    -- work with a custom dispatch as readily as an off-the-shelf one.
    K9DownDispatch       = true,

    -- shared/compat/*.lua. AUTO-DETECT WHAT YOU ACTUALLY RUN. Turn this on
    -- (it is on) and this resource works out which inventory, targeting,
    -- dispatch and ambulance script YOUR server runs, at startup, and talks
    -- to whichever one it finds -- instead of assuming everyone runs the
    -- same handful of scripts. Set it to `false` only if you want to pin
    -- every system by hand in Config.Compat below.
    --
    -- ONE HONEST EXCEPTION: your core FRAMEWORK is detected but not
    -- actually adapted to. This resource requires Qbox and will not run on
    -- qb-core or ESX regardless of what detection reports. The full
    -- explanation is on Config.Compat.Systems.framework further down --
    -- read it before assuming otherwise.
    -- Run /k9compat in game (see Config.Compat.diagnosticCommand) to print
    -- exactly what it found and what it could not find.
    ResourceAutoDetect   = true,

    -- server/leaderboard.lua. The /k9stats command: a ranked list of the
    -- top K9 handlers by XP. PRIVACY NOTE, decide this deliberately: it
    -- shows other people's citizen ids alongside their XP. The audience is
    -- bounded -- only someone who passes the same K9 access check as every
    -- other feature here can run it, not the whole server -- which is why
    -- it ships on. Set it to `false` if you would rather nobody saw anyone
    -- else's numbers, or leave it on and let high command switch it off for
    -- individuals from the tablet.
    K9Leaderboard        = true,

    -- server/training.lua + client/training.lua. A practice sandbox: a
    -- certified handler standing inside a Config.TrainingZones area can
    -- rehearse the search and bite-and-hold flow against a scripted dummy.
    -- Nothing in training mode touches a real target, a real inventory, or
    -- another player, and it deliberately awards ZERO XP -- a dummy has
    -- less friction than any real mechanic, so paying for it would be a
    -- faster route to the top tier than actual police work. Do not
    -- "restore" an award there.
    TrainingMode         = true,

    -- server/equipmentshop.lua + client/equipmentshop.lua. A "K9 Supply"
    -- shop selling the K9 items this resource uses. Without it those items
    -- exist in the code with nowhere on the map to buy them, which is how
    -- the wellbeing system currently ships. The shop itself, and every
    -- price and permission decision in it, lives inside your inventory
    -- script; this resource only registers it and puts a walk-up point on
    -- the map. If Config.K9EquipmentShop below is missing or every item in
    -- it is unknown to your inventory, the shop is simply not registered
    -- and one clear console line says so.
    K9EquipmentShop      = true,

    -- server/highcommand.lua. A senior-rank tier, defined per department by
    -- `highCommandGrade` in Config.Departments, that is exempt from EVERY
    -- other rank check in this resource and can mint XP directly via
    -- /k9givexp. See the Config.HighCommand block below for what it
    -- deliberately does NOT do (run arbitrary server commands) and why.
    -- This is the most powerful switch in this file: it is the only one
    -- that grants an in-game job rank write access to the XP economy.
    HighCommand          = true,

    -- server/permissions.lua. Lets high command grant a NAMED capability
    -- to one specific handler or K9, instead of everything being gated on
    -- job rank alone. Purely additive: grants widen access, never narrow
    -- it, so nothing that works on rank today stops working. See the
    -- Config.Permissions block below for the capability list and the
    -- exact resolution order.
    PermissionGrants     = true,

    -- client/tablet.lua + html/tablet.*. The in-game roster and control
    -- UI for certifications, XP and permission grants. It is a VIEW only
    -- -- every action is re-authorized server-side, so the tablet showing
    -- a button never makes an action allowed.
    CommandTablet        = true,

    -- server/bonetool.lua + client/bonetool.lua. A DEV-SERVER-ONLY sweep that
    -- attaches a marker prop to bone indices in sequence so a human can
    -- visually identify the right one for a quadruped skeleton -- the
    -- question that blocked PropAttachments and FetchMechanic through three
    -- research passes. This flag ALONE does not make the tool reachable: as
    -- of 2026-08-25 it also requires a replicated convar an operator must
    -- set on purpose (`setr qbx_k9unit_enable_bone_dev_tool 1`), and the
    -- caller must be a boss of a configured Config.Departments job. That
    -- second opt-in exists precisely because this flag was once flipped true
    -- alongside 39 others with nothing to distinguish it.
    -- Its real blast radius is narrow -- every effect is local to the
    -- caller's own client (a debug marker, and one non-networked prop on
    -- their own ped), and the server never accepts an entity or netId from
    -- the client -- but it is still a dev tool. Leave the convar unset on a
    -- production server.
    BoneSweepDevTool     = true,
    -- OPERATIONAL CAVEAT, and it matters most for THIS flag specifically.
    -- Nothing in this resource flips a Config.Features.* flag while running:
    -- every feature gates its RegisterCommand/RegisterNetEvent calls ONCE, at
    -- file-load or onResourceStart time. That is deliberate ("gate at
    -- registration, not inside the handler") and it is what makes a disabled
    -- feature genuinely inert rather than merely hidden.
    -- The consequence: turning this flag ON, restarting, then turning it back
    -- OFF does NOT unregister /k9bonetool. It stays reachable until the NEXT
    -- restart. For most features that is harmless. For this one it is not --
    -- it spawns and attaches props on command. RESTART AFTER DISABLING IT.
    -- (The ACE check still applies in that window; this is about not leaving
    -- a dev tool registered on a production server at all.)

    -- Phase 5 (audio/props/advanced vision R&D)
    AdvancedBarkRadial   = true,
    ProximityAudioFX     = true,
    PropAttachments      = true,
    FetchMechanic        = true,
    DeployableKennel     = true,
    -- client/vision.lua. CAMERA FEED — see what your partner sees.
    --
    -- A true picture-in-picture, two live views on screen at once, is
    -- genuinely impossible in FiveM. That was re-confirmed on 2026-08-26 by
    -- enumerating the entire camera namespace (202 calls) plus every
    -- render-target call against the live native list: nothing renders a
    -- camera into a texture. So it was not built, and no amount of asking
    -- will produce it.
    --
    -- What IS built, and works: press a key and your WHOLE screen switches
    -- to your partner's viewpoint, until you press it again. You need an
    -- active partnership. Honest limits, written up in full in
    -- client/vision.lua's own header: the eye height is an approximation
    -- per role rather than read off the skeleton, it follows their body
    -- rather than where they are looking, and it cuts out at normal
    -- streaming range.
    --
    -- Switched ON: real code now exists behind it, gated the same way every
    -- other departmental ability is, and it does nothing at all for someone
    -- with no partner. The name still says PiP for compatibility with
    -- anything referencing it.
    CameraFeedPiP        = true,

    -- server/certifications.lua. Opt-in periodic recertification: new
    -- grants get an expiry date and lapse unless renewed. OFF by default,
    -- and deliberately so -- but NOT because turning it on is destructive.
    -- It is not: every certification that already exists keeps no expiry
    -- date at all, forever, unless a certifier explicitly renews it. This
    -- comment used to say the opposite -- that switching it on started a
    -- clock retroactively on everyone -- and that was simply wrong, which
    -- would have scared an operator off a safe change. Only NEW grants and
    -- explicit renewals ever get an expiry.
    --
    -- It is off by default because starting a recertification cadence at
    -- all is a policy decision you should make on purpose, not inherit.
    -- Handlers get warned ahead of expiry; nobody should find out by an
    -- ability silently refusing to work.
    CertificationExpiry  = false,

    -- server/runtimecontrol.lua. Lets high command switch features on and
    -- off SERVER-WIDE from the tablet, and tune numbers live, without
    -- editing config.lua or restarting.
    -- READ THE ASYMMETRY BEFORE ENABLING, because it is a genuine engine
    -- constraint and not a bug: every feature in this resource gates its
    -- RegisterCommand and RegisterNetEvent calls ONCE, at load time. That
    -- is what makes a disabled feature genuinely inert instead of merely
    -- hidden. The consequence is that a runtime toggle can reliably turn a
    -- feature OFF (handlers re-check the live value and refuse), but
    -- turning one back ON cannot retroactively register handlers that were
    -- never registered at start -- that needs a restart. The tablet says
    -- so plainly rather than pretending otherwise.
    RuntimeFeatureControl = true,

    -- Lets high command restyle the tablet -- colours, density, header
    -- text -- from inside the tablet itself, saved server-side and applied
    -- for everyone. Cosmetic only: theming can never change what anyone is
    -- authorized to do or see.
    TabletTheming        = true,
}

-- ======================================================================
-- PED ROSTER — extensible, no code changes needed to add a streamed model.
--
-- ANY ped model works here. Nothing in this resource assumes a dog: every
-- check is a hash lookup against this list, so a custom streamed model --
-- a K9 pig, a bear, whatever your server streams -- is as valid as
-- a_c_shepherd. The ONLY requirement is that the model actually exists on
-- your server, streamed by some resource, before someone is assigned it.
--
-- Each entry may carry an optional `label`, which is what an officer sees
-- in the K9 Command Tablet when choosing a model. Without one the tablet
-- shows the raw model name, which is functional but ugly for a custom ped.
-- ======================================================================
-- Each entry may also carry an optional `speedMultiplier`, scaling how fast
-- that breed moves. Leave it out and the ped runs at a neutral 1.0 -- the
-- code reads it defensively, so an entry without it is not a bug. The
-- spread below is deliberately small: these are flavour, not a power
-- ranking. A number far above 1.0 turns breed choice into a required pick
-- rather than a preference, which is the opposite of what a roster is for.
-- ======================================================================
-- CERTIFICATION TIERS (Config.CertificationTiers) -- server/certtiers.lua.
--
-- The ranks WITHIN a K9 certification: trainee, certified, senior. High
-- command can add more, rename them, reorder them, and change what each
-- one grants -- from inside the K9 Command Tablet, while the server is
-- running. What is below is only the STARTING POINT. Anything high command
-- changes in the tablet is saved to the database and wins over this list.
--
-- DO NOT DELETE OR RENAME THESE THREE KEYS. Every certification already in
-- your database holds one of these three words. Changing them here would
-- orphan those records. Add new tiers freely; leave these three alone.
--
-- `capabilities` is empty on purpose, and as of 2026-08-26 that emptiness is
-- load-bearing rather than cosmetic. TWO capabilities now gate real mechanics:
-- ticking `bite_hold_and_takedown` on a tier means ONLY handlers in that tier
-- can bite or take down, and `specializations_eligible` means only that tier
-- can be given specializations. The other three gate nothing and say so.
--
-- Nothing is enforced until you tick the first box for a given capability. So
-- leaving these empty keeps every existing handler exactly as they are today
-- — and ticking one is a real restriction on everyone NOT in that tier, not a
-- preference. An operator who never opens the tablet sees no change at all.
-- ======================================================================
Config.CertificationTiers = {
    { key = 'trainee',   label = 'Trainee',   ordinal = 1, capabilities = {} },
    { key = 'certified', label = 'Certified', ordinal = 2, capabilities = {} },
    { key = 'senior',    label = 'Senior',    ordinal = 3, capabilities = {} },
}

Config.Peds = {
    { model = 'a_c_shepherd',   speedMultiplier = 1.00 },
    { model = 'a_c_rottweiler', speedMultiplier = 0.98 },
    { model = 'a_c_husky',      speedMultiplier = 1.03 },
    { model = 'a_c_chop',       speedMultiplier = 1.00 },
    -- Example custom streamed model (requires the model to exist in a
    -- streamed resource elsewhere on the server; adding this line is the
    -- *only* change needed to make it selectable):
    -- { model = 'a_c_k9_malinois', label = 'Belgian Malinois' },
    --
    -- A custom model does not have to be a dog. This is a real, supported
    -- configuration -- the resource never checks the species:
    -- { model = 'a_c_pig', label = 'K9 Pig' },
}

-- ======================================================================
-- K9 APPEARANCE — what happens to a player's own character when they are
-- made a K9.
--
-- Until now this resource only ever DETECTED whether someone was already
-- playing a K9 model; it never set one. With this on, certifying someone
-- (or granting them k9.access) actually turns their character INTO the
-- ped, and revoking turns them back.
--
-- THIS CHANGES A PLAYER'S CHARACTER, so it is worth understanding before
-- switching it on:
--   * The change is server-authoritative. A client cannot make itself a
--     K9; it asks, and the server decides from the same certification and
--     permission checks everything else in this resource uses.
--   * It persists. The assignment is stored against the citizenid, so a
--     relog, a crash or a server restart brings them back as the K9 --
--     otherwise every K9 would silently turn back into a person on the
--     next disconnect.
--   * The player's ORIGINAL appearance is recorded before the swap, so
--     revoking restores what they actually looked like rather than a
--     default. If that record is missing (an install where someone was
--     already a K9 before this feature existed), revoking falls back to a
--     configured model rather than leaving them stuck as an animal.
-- ======================================================================
Config.K9Appearance = {
    -- Master switch. With this false the resource behaves exactly as it did
    -- before: it detects K9 models but never assigns one, and an operator
    -- handles appearance through whatever character system they already run.
    applyPedModelOnCertify = true,

    -- DOES HOLDING THE K9 ROLE REQUIRE BEING A K9 MODEL?
    --
    -- false (the default) decouples the two completely: the K9 ROLE is an
    -- assignment the server holds against a citizenid, and the ped model is
    -- just what that character happens to look like. Someone on a model
    -- that is not in Config.Peds -- including an ordinary human ped, or a
    -- custom one you never listed -- can still be given the K9 role and use
    -- every K9 ability.
    --
    -- Why this is the default: the model check was only ever a convenience,
    -- and tying a role to an appearance breaks the moment someone uses a
    -- character system this resource does not control, streams a model that
    -- was not on the list, or is mid-swap when a check runs. The role is
    -- the fact; the model is cosmetic.
    --
    -- true restores the older, stricter behaviour: only a configured K9
    -- model may hold the role. Use it if you want the appearance to be the
    -- enforcement, and accept that anyone on an unlisted model is locked
    -- out until you add it to Config.Peds.
    --
    -- Either way this is a CONVENIENCE gate, never a security one. Every
    -- server-side action re-checks certification and permissions
    -- independently of what anyone looks like.
    requireK9ModelForRole = false,

    -- Whether the assignment survives a relog. Almost always true -- with
    -- it false a K9 reverts to their normal character on every disconnect,
    -- which reads as the feature being broken.
    persistAcrossSessions = true,

    -- Whether revoking a certification restores the player's previous
    -- appearance. Leaving this false strands them as an animal with no way
    -- back, so turn it off only if your own character system takes over
    -- that job.
    restoreOriginalPedOnRevoke = true,

    -- Fallback model used ONLY when someone's original appearance was never
    -- recorded and cannot be restored. Set it to something harmless that
    -- definitely exists on your server.
    fallbackHumanModel = 'a_m_m_business_01',

    -- How long to wait for a model to stream in before giving up, in ms.
    -- A custom addon ped can be slower to load than a vanilla one. On
    -- timeout the swap is abandoned and the player is left as they were --
    -- never half-applied, and never stuck invisible.
    modelLoadTimeoutMs = 10000,
}

-- ======================================================================
-- DEPARTMENTS — admin-editable list of job names with K9 access, plus the
-- rank threshold required to grant/revoke certifications for that job.
-- ======================================================================
Config.Departments = {
    ['police'] = {
        label           = 'Los Santos Police Department',
        certifierGrade  = 4,    -- job.grade.level required to grant/revoke certs (job.isboss always qualifies too)
        -- job.grade.level required to run the read-only /k9audit* commands.
        -- These were ACE-gated until 2026-08-25 and are now gated on police
        -- rank instead, at the project owner's request: auditing K9
        -- certifications is a senior-officer function, not a server-admin
        -- one. Set at or above certifierGrade -- someone trusted to grant a
        -- certification should be able to see who holds one. job.isboss
        -- always qualifies, same as certifierGrade.
        auditGrade      = 4,
        -- HIGH COMMAND. A caller at or above this grade -- job.isboss also
        -- always qualifies -- BYPASSES EVERY OTHER RANK GATE IN THIS
        -- RESOURCE: certifierGrade, auditGrade, the bone dev tool's
        -- boss-only check, and the K9 certification requirement itself. It
        -- is the single "senior command can do anything this resource
        -- offers" switch, and it is what unlocks /k9givexp.
        --
        -- SET THIS DELIBERATELY, AND HIGHER THAN auditGrade. Unlike every
        -- other threshold here it grants WRITE power over the economy: a
        -- high command officer can mint XP out of nothing. Every use is
        -- logged to the server console with who granted what to whom.
        --
        -- nil disables the tier entirely for this department. nil means
        -- "no such rank exists here", NEVER "everybody qualifies" -- the
        -- check fails closed on a nil, a non-number, or a malformed grade.
        highCommandGrade = 6,
        -- job.grade.level required to RECEIVE non-compliance alerts (a K9's
        -- target resisting or fleeing). Deliberately a separate, much lower
        -- bar than auditGrade: an audit pull exposes who searched whom and
        -- is a privacy boundary, whereas this alert carries no
        -- citizen-identifying data at all -- just a source id and a speed or
        -- displacement number. It is closer to a dispatch broadcast than to
        -- a records lookup, so it defaults to 0, meaning every sworn member
        -- of a configured department sees them. job.isboss always qualifies.
        -- nil disables the alerts entirely for this department; it never
        -- means "everybody".
        nonComplianceAlertGrade = 0,
        autoAccessGrade = nil,  -- nil = no auto-bypass; set an integer to let that grade+ skip certification (see §4.1 assumption)
    },
    ['sheriff'] = {
        label           = 'Blaine County Sheriff',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 5, -- see police.highCommandGrade above for what this unlocks
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },
    ['bcso'] = {
        label           = 'Blaine County Sheriff (legacy job name)',
        certifierGrade  = 3,
        auditGrade      = 3,
        highCommandGrade = 5, -- see police.highCommandGrade above for what this unlocks
        nonComplianceAlertGrade = 0, -- see police.nonComplianceAlertGrade above
        autoAccessGrade = nil,
    },
}

-- ======================================================================
-- HIGH COMMAND (Config.Features.HighCommand) -- server/highcommand.lua.
--
-- What it is: a single senior-rank tier, defined per department by
-- `highCommandGrade` above, that is exempt from every other rank check in
-- this resource and can additionally mint XP directly.
--
-- WHAT IT DELIBERATELY IS **NOT**: a way to run arbitrary server commands.
-- "High command can run any command" was requested, and within this
-- resource that is exactly what this delivers -- every qbx_k9unit command
-- and every gated action becomes available. It stops at this resource's
-- boundary on purpose. A generic passthrough that let an in-game job rank
-- execute arbitrary server commands would turn a promotion into full
-- server control across EVERY resource installed, including ACE and
-- permission management -- so one social-engineered promotion, or one
-- compromised officer account, would own the server with no way to walk
-- it back. That is a server-admin capability (txAdmin, ACE) and it should
-- stay one. If you want it anyway it is your server and your call -- say
-- so and it can be added, but it should be a deliberate decision rather
-- than a side effect of a rank number.
-- ======================================================================
Config.HighCommand = {
    -- Max XP a single /k9givexp invocation may grant. This is a typo
    -- guard, not a trust boundary -- high command is already trusted, but
    -- an accidental extra zero should not silently mint a fortune. Raise
    -- it if your progression curve is larger; a non-positive or
    -- non-number value here disables the command rather than meaning
    -- "unlimited", matching this resource's fail-closed convention.
    maxXpPerGrant = 5000,

    -- Anti-fat-finger cooldown between grants from the same officer, in ms.
    -- Deliberately short: this is not a rate limit against abuse (high
    -- command is trusted by definition), it is protection against a held
    -- key or a double-submitted chat line.
    grantCooldownMs = 1500,

    -- Whether high command may grant XP to THEMSELVES. OWNER DECISION:
    -- "High command can grant anything they want to themselves -- xp
    -- promotions permissions etc" -- so this now DEFAULTS TRUE, matching
    -- Config.FeatureControl.allowHighCommandSelfGrant below (self-grant of
    -- a permission/feature/block entry), which this pass also widened and
    -- defaults true. The self-grant is never invisible either way:
    -- server/highcommand.lua audits every '/k9givexp' invocation with an
    -- explicit `self_grant=true/false` field naming the SAME citizenid as
    -- both granter and recipient whenever it fires, so "high command gave
    -- themselves XP" is always a distinguishable, greppable line, not a
    -- silent mint. Set this to `false` if your server wants the STRICTER,
    -- pre-owner-decision behaviour back -- a self-grant is the one case
    -- with no second person in the audit trail, and some operators may
    -- still want a peer to be the one who presses the button even though
    -- nothing stops that peer from being asked. Read as `~= false`
    -- wherever this is consulted, never `x or default`, so an explicit
    -- `false` is never misread as "not set".
    allowSelfGrant = true,
}

-- ======================================================================
-- GRANTABLE PERMISSIONS (Config.Features.PermissionGrants) --
-- server/permissions.lua.
--
-- The problem this solves: until now every capability in this resource
-- was gated on JOB RANK alone. That works for "all sergeants may certify"
-- but not for "this one officer may certify, and nobody else at their
-- rank may". High command can now grant a named permission to a specific
-- person -- a handler OR a K9, since both are just citizenids -- and
-- revoke it later, with the whole history recorded.
--
-- HOW A CAPABILITY CHECK RESOLVES, in order. First match wins:
--   1. an active, explicitly granted permission for that citizenid  -> ALLOW
--   2. the caller is high command (Config.Departments highCommandGrade) -> ALLOW
--   3. the caller meets the legacy rank gate (certifierGrade etc.)   -> ALLOW
--   4. otherwise                                                     -> DENY
-- This is purely ADDITIVE. Nothing that works on rank today stops
-- working; grants only ever widen access, never narrow it. If you want
-- to take a capability away from someone who qualifies by RANK, change
-- their rank -- revoking a grant they never had does nothing, and the
-- UI says so rather than pretending it worked.
--
-- Keys are the capability names. Do not rename one after granting it:
-- the grant rows store this string, so a rename silently orphans every
-- existing grant. Add a new key and migrate instead.
-- ======================================================================
Config.Permissions = {
    -- The label is what a non-technical officer sees in the tablet, so
    -- write it as a sentence about what the person can DO.
    ['k9.access']  = { label = 'Use K9 abilities',              description = 'Equivalent to holding a K9 certification. Grant this to let someone work as a K9 without going through a certifying officer.' },
    ['k9.certify'] = { label = 'Certify and decertify others',  description = 'Grant and revoke K9 certifications. Normally requires a senior rank; this hands it to one specific person.' },
    ['k9.audit']   = { label = 'View the audit records',        description = 'Run the read-only audit commands. PRIVACY-SENSITIVE: this reveals who searched whom, and when.' },
    ['k9.givexp']  = { label = 'Grant XP',                      description = 'Award XP directly to a K9 or handler. This mints economy value -- every use is logged.' },
}

-- ======================================================================
-- PER-PERSON FEATURE CONTROL --
--
-- The four capabilities above are about ADMIN powers. This block is about
-- the K9 abilities themselves: high command can turn an individual
-- feature on or off for ONE specific K9 or handler, rather than only
-- globally for the whole server.
--
-- HOW A FEATURE RESOLVES FOR A GIVEN PERSON. First match wins:
--   1. Config.Features.<Name> is false      -> DENY, always, no exceptions
--   2. an explicit BLOCK row for them       -> DENY
--   3. <Name> is listed in RequireGrant     -> ALLOW only if they hold a grant
--   4. otherwise                            -> ALLOW
--
-- Step 1 is deliberately absolute. A per-person grant can NEVER switch on
-- something an operator turned off server-wide: if the global flag is
-- false the code behind it may not even be registered, so "granting" it
-- would produce a button that silently does nothing. Global off means off.
--
-- Step 2 exists because "disable it for this one person" is a real need
-- (a handler under review, a K9 abusing a mechanic) and is NOT the same
-- as revoking a grant. Revoking only removes a grant they were given;
-- a block overrides everything below it, including step 4's default-allow.
--
-- Grants and blocks live in the same k9_permissions table as the
-- capabilities above, keyed `feature.<Name>` and `block.<Name>` -- so they
-- inherit the same audit trail, the same one-active-row-per-key
-- guarantee, and the same revoke-never-delete rule for free.
-- ======================================================================
Config.FeatureControl = {
    -- Features that need an explicit per-person grant even when their
    -- global flag is on. Anything not listed here stays available to
    -- everyone, which is the behaviour before this feature existed --
    -- so an empty table changes nothing.
    --
    -- HOW TO ACTUALLY GRANT ONE OF THESE: normally the K9 tablet (below).
    -- If Config.Features.CommandTablet is off, or Config.CommandTablet.openMode
    -- is 'item' with no chat-command fallback, the tablet cannot do this --
    -- but everything listed here can STILL be granted/revoked with the
    -- '/k9grantpermission [citizenid] [permissionKey]' and
    -- '/k9revokepermission [citizenid] [permissionKey]' chat commands
    -- (server/permissions.lua), which require the exact same High Command
    -- authorization the tablet does and work regardless of the tablet's
    -- own on/off state. A startup warning (also server/permissions.lua)
    -- names the affected features and points at these commands whenever
    -- both conditions above are true at once.
    --
    -- These four default to grant-required because they are the ones that
    -- act ON another player rather than on the K9 itself, so "who is
    -- allowed to do this" is a decision a server will actually want to
    -- make per person rather than per rank.
    RequireGrant = {
        BiteAndHold       = true,
        NonLethalTakedown = true,
        PropDragging      = true,
        AdminAuditCommands = true,
        -- FindAlerts does NOT fit the "acts on another player" rationale
        -- above -- it is cosmetic and affects only the searcher's own
        -- character. It is listed anyway because the requirement is that
        -- high command can switch ANY feature on or off for an individual,
        -- not only the dangerous ones. Treat the paragraph above as the
        -- reason the original four were chosen, not as a rule limiting what
        -- may appear here.
        FindAlerts        = true,
        -- Listed for a different reason than the four above: not because it
        -- acts on another player (it does not), but so high command can
        -- phase the hunt in per person -- reserve it for K9s who have
        -- finished search training, or stage a rollout -- instead of only
        -- being able to flip it for the whole server at once.
        ScentTrailHunt    = true,
        PursuitSprint     = true,
        -- Fits the original "acts on another player" rationale squarely:
        -- a lineup summons named players and then publicly names one of
        -- them as the match.
        ScentLineup       = true,
        SARCalls          = true,
    },

    -- OWNER DECISION (this pass -- server/permissions.lua's own
    -- "SELF-GRANT" header section documents the full reasoning this
    -- implements; read that before changing this). The project owner's own
    -- words: "High command can grant anything they want to themselves --
    -- xp promotions permissions etc." This flag now governs self-grant for
    -- EVERY permission namespace server/permissions.lua validates: a
    -- high-command officer granting THEMSELVES a 'feature.<Name>'/
    -- RequireGrant entry from THIS table, a 'block.<Name>' entry, OR one of
    -- the four named capabilities (k9.access/k9.certify/k9.audit/
    -- k9.givexp) from Config.Permissions above -- all four are the SAME
    -- decision to the owner, and are now WIDENED (this pass) from a
    -- previous version that exempted 'feature.<Name>' alone. Every grant
    -- issued through this flag still requires the officer to independently
    -- already BE high command (server/permissions.lua's GrantPermission
    -- re-verifies IsHighCommand server-side on every call, from the
    -- caller's own live job, never a client claim) -- this flag only ever
    -- changes what an ALREADY-VERIFIED high-command officer may do to
    -- their own citizenid, never who counts as high command.
    --
    -- HISTORY, FOR CONTEXT: this flag was originally added to close a
    -- genuine day-one deadlock on the single most common topology there
    -- is -- a server with exactly ONE high-command officer (the owner, on
    -- day one, before any second officer is promoted): with self-grant of
    -- 'feature.<Name>' blocked outright, nobody could ever grant that
    -- officer 'feature.AdminAuditCommands' (or any other RequireGrant
    -- entry above), permanently locking the tablet's entire Audit tab. The
    -- four named capabilities and 'block.<Name>' were deliberately left out
    -- of that earlier fix, since a high-command officer already bypasses
    -- those checks directly via IsHighCommand regardless of any grant, so
    -- self-granting them fixed no deadlock. That reasoning still holds --
    -- it is simply no longer the deciding factor now that the owner has
    -- asked for self-service across the board as a matter of what his
    -- server should allow, not as a bug fix.
    --
    -- DEFAULT TRUE, matching Config.HighCommand.allowSelfGrant above (this
    -- pass flipped that flag's own default to match, for the identical
    -- reason: the owner's decision applies uniformly, not per-mechanism).
    -- Every self-grant issued under this default is still audited and
    -- distinguishable from an ordinary grant -- server/permissions.lua's
    -- LogAuditInvocation prints an explicit `self=true/false` field on
    -- every GrantPermission audit line, naming the SAME citizenid as both
    -- granter and recipient whenever it fires. Self-service is the owner's
    -- decision; invisible self-service is not something this resource
    -- ships quietly.
    --
    -- Set this to false if your server wants the STRICTER, pre-owner-
    -- decision behaviour back instead -- a second high-command officer's
    -- own action required on every grant, even to another high-command
    -- officer, even for a capability IsHighCommand already grants them
    -- directly -- and accepts that a server with exactly one high-command
    -- officer then has NO way to grant that officer any RequireGrant-listed
    -- feature (Audit tab included), any named capability, or any block
    -- entry, until a second high-command officer is promoted. Read as
    -- `~= false` wherever this is consulted, never `x or default`, so an
    -- explicit `false` is never misread as "not set".
    allowHighCommandSelfGrant = true,

    -- Whether a handler/K9 may open the tablet and see what they hold.
    -- Everyone gets the read-only view of their own record by default --
    -- that is the point of it. Turning this off leaves the tablet as a
    -- high-command-only tool.
    everyoneCanViewOwnRecord = true,

    -- Whether the tablet may TRIGGER an ability, as an alternative to the
    -- keybind or chat command. The tablet never grants permission to do
    -- anything -- it fires exactly the same server-validated path the
    -- command does, so a person can only trigger what they could already
    -- trigger by typing it.
    allowActionsFromTablet = true,
}

-- ======================================================================
-- K9 COMMAND TABLET (Config.Features.CommandTablet) --
-- client/tablet.lua + html/tablet.*. The in-game UI for everything
-- above: a roster of handlers and K9s with their certifications, XP and
-- granted permissions, and the controls to grant or revoke.
--
-- SECURITY NOTE, because a UI makes this easy to get wrong: the tablet
-- is a VIEW. It decides nothing. Every action it offers is re-authorized
-- server-side from the caller's own live job and grants, exactly as if
-- they had typed the command -- a modified client can send any NUI
-- callback it likes, so the tablet showing a button must never be what
-- makes the action allowed. It only hides what you cannot do, as a
-- convenience.
--
-- BUT: turning Config.Features.CommandTablet off below does not just
-- remove that "VIEW" -- it also removes the ONLY way this tablet offers to
-- grant/revoke a Config.FeatureControl.RequireGrant feature (above) or any
-- Config.Permissions capability. See Config.FeatureControl's own header
-- above for the chat-command fallback ('/k9grantpermission'/
-- '/k9revokepermission') that keeps working regardless of this flag.
-- ======================================================================
Config.CommandTablet = {
    -- HOW PLAYERS OPEN THE TABLET. Pick one:
    --   'command' -- a chat command only. No item needed. Simplest, and the
    --                right choice if you do not want another inventory item
    --                to manage.
    --   'item'    -- using an ox_inventory item opens it. The command is not
    --                registered at all in this mode, so there is no way to
    --                open it without the item in hand.
    --   'both'    -- either works. The item is a convenience, not a gate.
    -- Any other value is treated as 'command' and warns loudly at startup,
    -- rather than silently leaving players with no way in at all.
    openMode = 'both',

    -- The chat command, used by 'command' and 'both'. Also reachable from
    -- the K9 radial menu in every mode -- the radial is a UI affordance, not
    -- a third open mode, and it honours the same authorization either way.
    command = 'k9tablet',

    -- A SECOND, separate chat command that opens the SAME tablet, but goes
    -- straight to the High Command console screen instead of the player's
    -- own record -- a shortcut for your senior staff so they don't have to
    -- open the tablet and click across to the console tab every time.
    --
    -- This is only ever a shortcut to a SCREEN, never a way to grant
    -- access: someone who is not High Command and types this command still
    -- gets refused the console (with a message explaining why) and simply
    -- sees their own record instead, exactly as the regular command above
    -- would show them. Always available (regardless of `openMode` above)
    -- whenever this tablet feature is turned on at all. Rename it to
    -- whatever fits your server, or leave it as the default below.
    highCommandCommand = 'k9hqtablet',

    -- The ox_inventory item, used by 'item' and 'both'.
    --
    -- READ THIS BEFORE SETTING openMode = 'item': the item must already
    -- exist in YOUR ox_inventory items table. This resource cannot create
    -- it, and an unregistered name resolves to a count of zero forever --
    -- which, in 'item' mode, means NOBODY can open the tablet and nothing
    -- explains why. A startup warning fires if the name cannot be resolved,
    -- and in 'item' mode that warning is escalated, because there is no
    -- command to fall back on. Four other placeholder item names in this
    -- config have the same requirement (k9_medkit, k9_treat, k9_meat_bait,
    -- k9_ultrasonic_whistle); see the operator runbook's checklist.
    itemName = 'k9_tablet',

    -- NOT AN ENFORCED SWITCH -- READ BEFORE CHANGING (dead-config-field
    -- audit finding: this field's own comment used to read like an
    -- ordinary toggle and never disclosed that it does nothing on its own).
    -- Nothing in this resource reads this value at all. ox_inventory
    -- consumes (or does not consume) k9_tablet purely per that item's OWN
    -- `consume` field in YOUR ox_inventory items.lua, which this resource
    -- does not own and cannot set. This field is a NOTE describing what you
    -- should ALSO set your item's `consume` field to (0/false for a
    -- reusable tablet, matching the "almost certainly false" default
    -- below), not a control this resource enforces -- flipping it here
    -- changes nothing in-game until you separately edit items.lua to
    -- match. See client/tablet.lua's own useTabletItem handler for the
    -- full mechanism this note describes.
    consumeItemOnUse = false,

    -- Max roster rows returned in one query. Clamped server-side; a
    -- non-positive or non-number value falls back to the default rather
    -- than meaning "unlimited".
    maxRosterRows = 100,

    -- Which features get a one-click "use" button in the tablet.
    --
    -- Everything in your Config.Features list is SHOWN in the tablet with
    -- its current state. This much smaller list is the subset that can also
    -- be TRIGGERED from there -- the ones where a single button press has an
    -- obvious meaning ("bark", "toggle night vision"). A feature not listed
    -- here still appears and still works; it just has no button, because
    -- there is nothing sensible for one press to do.
    --
    -- These 20 are exactly the features the tablet actually knows how to
    -- fire today. Setting one to false removes its button. Adding a key
    -- that has no wiring behind it gives you a button that does nothing,
    -- so only add one alongside the code that makes it work.
    --
    -- This table did not exist until 2026-08-26, and the tablet read it
    -- anyway -- which meant NO feature got a button, on any server. If you
    -- delete this table, that is the behaviour you go back to.
    ActionableFeatures = {
        LeashMechanics    = true,
        VehicleEntryExit  = true,
        BasicBarkSounds   = true,
        ScentTracking     = true,
        BloodTracking     = true,
        GunpowderSniffing = true,
        ThermalVision     = true,
        NightVision       = true,
        BiteAndHold       = true,
        NonLethalTakedown = true,
        PropDragging      = true,
        HandlerPartnership = true,
        Recall            = true,
        HandlerDownDefense = true,
        FetchMechanic     = true,
        PropAttachments   = true,
        DeployableKennel  = true,
        K9Inventory       = true,
        K9Medkit          = true,
        FearStressSystem  = true,
    },
    -- ==================================================================
    -- YOUR SERVER'S BRANDING ON THE TABLET. The tablet now shows this logo
    -- in several places (the header on every screen, plus a larger badge
    -- on the opening/loading screen) -- you do not choose where; it is
    -- placed automatically everywhere it makes sense.
    --
    -- TO USE YOUR OWN LOGO: save it as html/images/logo.png, replacing the
    -- placeholder that ships there. That is the only step -- you do not
    -- need to edit anything else in this file or in fxmanifest.lua, and
    -- you do not need to restart anything other than the resource.
    --
    -- WHAT IMAGE TO USE: a SQUARE image (same width and height, e.g.
    -- 512x512 or 1024x1024) looks best -- that is the shape the tablet's
    -- layout is built around. A non-square image (a wide banner or a tall
    -- crest) still displays correctly and is never stretched or squashed,
    -- but a square badge is the recommended shape.
    --
    -- WHAT NOT TO USE: a web address (anything starting with http:// or
    -- https://). The tablet's security settings only allow it to load
    -- files shipped with this resource, so a web address will silently
    -- fail to load -- it will not show an error, it will just fall back
    -- to showing `serverName` as plain text below, exactly as if the file
    -- were missing. Always use a local file under html/images/.
    --
    -- If the file is missing, unreadable, or otherwise fails to load, the
    -- tablet falls back to showing `serverName` as text everywhere the
    -- logo would have appeared. It never shows a broken-image icon and
    -- never leaves an empty gap.
    -- ==================================================================
    branding = {
        -- Shown beside the logo, and instead of it if the image cannot
        -- load. Keep it short -- it sits in a header, not a paragraph.
        serverName = 'Crimson Roleplay',

        -- Where the logo lives. Change this only if you also add the new
        -- path to fxmanifest.lua's files{} block -- an image the manifest
        -- does not list is simply not sent to players, and shows as
        -- nothing with no error to explain why. Must be a local path
        -- under html/ -- see the "WHAT NOT TO USE" note above.
        logo = 'images/logo.png',

        -- Starting colours, matched to the shipped logo (crimson red on
        -- near-black). High command can change all of these live from the
        -- tablet itself; these are just what a fresh install looks like.
        -- Hex, six digits, with the #.
        theme = {
            primaryColor    = '#C8102E', -- crimson: headers, active tabs
            accentColor     = '#FF2D2D', -- brighter red: buttons, highlights
            backgroundColor = '#0B0B0D', -- near-black panel background
            textColor       = '#F5F5F5', -- off-white body text
        },
    },

}

-- ======================================================================
-- CERTIFICATION DEPTH -- tiers, expiry and specializations.
--
-- Tiers (trainee / certified / senior) are deliberately HARDCODED in
-- server/certifications.lua rather than configured here. A fixed, ordinal
-- three-step vocabulary cannot be misconfigured into something the gate
-- code is unable to rank, and an operator can hold the whole model in
-- their head. If you want finer-grained distinctions, use specializations
-- below -- that is what they are for.
-- ======================================================================

-- Days from grant or renewal until a certification is treated as expired.
-- Only consulted when Config.Features.CertificationExpiry is true. A
-- non-positive or non-number value disables expiry-setting rather than
-- meaning "immediately" or "never" -- this resource's usual fail-safe
-- convention for a boundary value.
Config.CertificationExpiryDays = 90

-- How many days ahead of expiry an online handler starts getting a
-- one-per-session warning. Nobody should discover their certification
-- lapsed by an ability silently refusing to work.
Config.CertificationExpiryWarningDays = 7

-- How often the background sweep re-checks online handlers for an
-- upcoming or just-passed expiry. NOT the enforcement point: HasK9Access
-- and RefreshCertificationCache always compute the true state fresh on
-- login, grant and revoke regardless of this interval. This only drives
-- the courtesy notifications.
Config.CertificationExpiryCheckIntervalMs = 300000

-- Named K9 training specializations a certifier can grant on top of an
-- existing active certification. Add freely -- but the keys are stored in
-- the database, so never RENAME one that has already been granted; add a
-- new key and migrate, the same rule Config.Permissions carries.
Config.K9Specializations = {
    narcotics  = { label = 'Narcotics detection' },
    explosives = { label = 'Explosives detection' },
    patrol     = { label = 'Patrol / apprehension' },
}

-- ======================================================================
-- K9 DOWN ALERT (Config.Features.K9DownDispatch) -- server/integrations.lua.
-- Tuning for OUR OWN detection of a K9 going down. This is not an
-- integration surface: there is nothing here naming another resource,
-- because the alert is a broadcast event any system can listen for.
-- ======================================================================
Config.K9DownDispatch = {
    -- Health at or below which a K9 counts as down. Mirrors the same
    -- threshold server/wellbeing.lua uses. Raise it to get an earlier
    -- "going critical" warning instead of an "already down" one.
    healthThreshold  = 100,

    -- How long they must stay down before the alert fires, in ms. This is
    -- the debounce: without it, a momentary dip through the threshold
    -- during an ordinary firefight would page dispatch. 0 disables it.
    minDurationMs    = 3000,

    -- Background poll interval, in ms.
    pollIntervalMs   = 2000,

    -- Minimum gap between two alerts for the SAME K9, in ms. Stops a
    -- handler bleeding out from generating a stream of alerts. Must be
    -- positive -- a non-positive value here is caught by cooldowns.lua's
    -- own guard. Setting this to 0 or a negative number does NOT mean "no
    -- cooldown" and never did -- but as of 2026-08-26 it no longer breaks
    -- anything either. It used to abort server/integrations.lua at startup,
    -- silently killing K9-down dispatch for the rest of that server's
    -- uptime. Now a bad value is clamped back to the 30000 below and warned
    -- about loudly in your console, naming this exact key. A suppressed
    -- episode is DEFERRED, not dropped.
    reFireCooldownMs = 30000,
}

Config.AllowSelfCertification = true   -- see §4.1
Config.CertifyProximityMeters = 5.0    -- server-enforced max distance for grant/revoke (§4.2.4)

-- ======================================================================
-- VEHICLES — which vehicle models expose the "Load K9" / "Release K9"
-- ox_target option on their trunk/rear door.
-- ======================================================================
Config.K9Vehicles = {
    'police', 'police2', 'police3', 'police4', 'sheriff', 'sheriff2',
}
Config.VehicleInteractMeters = 3.0

-- ======================================================================
-- LEASH — Phase 1
-- ======================================================================
-- Base/reference leash range in meters (§6.1 — two-player leash, not a
-- recall; see server/main.lua and client/movement.lua headers for the
-- corrected model). NOT itself the auto-detach threshold — that's a
-- common misreading of this field's old comment. Three different
-- call sites derive or reuse this single value for three distinct
-- purposes, each documented in full where it's used:
--   - client/movement.lua derives the elastic pull-back START (75% of
--     this value, LEASH_PULL_ZONE_FACTOR) and the actual hard-cap
--     safety-valve auto-detach (150% of this value, LEASH_HARD_CAP_FACTOR)
--     from it — for the default below, real auto-detach fires around 12m,
--     not 8m.
--   - server/main.lua's CheckLeashEligibility reuses this raw value
--     directly as the max range to even INITIATE a leash request (a
--     separate "too far to request" check, distinct from auto-detach).
--   - client/radial.lua's FindNearestLeashCandidate reuses this raw value
--     directly as its nearby-partner search radius.
-- Reusing the raw value (rather than dedicated constants) for the latter
-- two is a deliberate Phase 1 default, not an oversight — see server/
-- main.lua's header for the open question on whether a separate,
-- smaller "attach range" constant would be worth adding later.
Config.LeashMaxDistance = 8.0

-- ======================================================================
-- LEASH VISUAL (client/leashvisual.lua) -- makes the leash mechanic above
-- actually VISIBLE: a rendered rope between the handler and the K9 for the
-- whole duration of an active leash, plus a leash-handle prop on the
-- handler's own hand. Rides entirely on top of Config.Features.LeashMechanics
-- above rather than being its own togglable feature area -- there is no
-- separate Config.Features entry for this, since with LeashMechanics off
-- the leashAttached/leashDetached events this file reacts to never fire at
-- all, and it is automatically fully inert either way. `enabled` below is
-- purely an extra operator kill-switch for the VISUAL specifically (e.g. a
-- very high-population server that wants the mechanic but not the extra
-- rope/prop entities), independent of that.
--
-- BONE INDICES -- SAME HONEST DEFAULT AS Config.PropAttachments BELOW (read
-- that block's own header first; this is the exact same situation, not a
-- new one). AttachEntitiesToRope takes bone-relative OFFSETS derived from
-- these indices (client/leashvisual.lua's GetBoneLocalOffset), never a bone
-- NAME string -- this resource's research has never found a confirmed bone
-- NAME for the a_c_* K9 skeleton (see Config.PropAttachments/
-- client/bonetool.lua), and never went looking for one on the human
-- skeleton for this feature either, so both indices below default to 0
-- (root -- always valid, never crashes, looks wrong: the rope anchors near
-- each ped's own center rather than precisely a collar/hand point).
-- Refine with Config.Features.BoneSweepDevTool (works on ANY currently-worn
-- ped model, human or K9 -- it is not K9-specific) and set the real values
-- here once found.
Config.LeashVisual = {
    enabled = true,

    -- Bone index the rope's K9-side endpoint offsets from (the K9's own
    -- ped).
    k9BoneIndex = 0,
    -- Bone index the rope's officer-side endpoint offsets from (the
    -- handler's own ped) -- ALSO reused as the attach bone for
    -- handleModel/handleFallbackModel below, since both represent the same
    -- "where on the handler's body does the leash line originate" point.
    officerBoneIndex = 0,

    -- Rope look/feel. ropeType is a zero-based index into ropedata.xml
    -- (AddRope's own documented set, game build 3258): 0 = RopeThin, the
    -- thinnest and most leash-like of the 8 shipped types (1/2/7 are
    -- steel-cable textured, meant for tow cables). AddRope's own docs state
    -- an out-of-range ropeType CRASHES THE GAME -- client/leashvisual.lua
    -- clamps this to [0, 7] defensively rather than trusting it blindly,
    -- but this should still never be hand-edited outside that range.
    ropeType = 0,
    -- The rope's maximum droop/extend length, in meters. Deliberately
    -- LARGER than Config.LeashMaxDistance above rather than equal to it: a
    -- rope whose max length exactly matched the real enforced range would
    -- look taut/rigid at all times, right up to the exact moment
    -- client/movement.lua's own elastic pull-back (LEASH_HARD_CAP_FACTOR =
    -- 1.5) kicks in. Sized to roughly that same 1.5x factor here (8.0 * 1.5
    -- = 12.0) so the rope only looks genuinely taut right around where the
    -- real mechanic starts correcting distance, and hangs with a natural
    -- droop well inside that. Kept as its OWN independent field (not a
    -- computed `Config.LeashMaxDistance * 1.5` expression) so an operator
    -- can retune the cosmetic droop without touching the mechanic's own
    -- range, or vice versa.
    ropeMaxLengthMeters = 12.0,
    -- The rope's minimum length, in meters -- how slack it can go when the
    -- two peds are close together. 0.0 lets it go fully slack, the correct
    -- look for two people standing close.
    ropeMinLengthMeters = 0.0,

    -- Bounded wait for RopeAreTexturesLoaded() before giving up on ever
    -- rendering a rope for the rest of THIS client's session
    -- (client/leashvisual.lua's EnsureRopeTexturesLoaded) -- same
    -- "generous ceiling, then fail loudly rather than hang forever"
    -- reasoning as REQUEST_MODEL_TIMEOUT_MS elsewhere in this resource
    -- (client/kennel.lua, client/propattachment.lua).
    ropeTextureTimeoutMs = 5000,

    -- Leash-handle prop attached to the HANDLER's (officer-role party's)
    -- own hand for the leash's duration -- UNVERIFIED, same honest
    -- disclosure as Config.PropAttachments.propModel below: no confirmed
    -- GTA V leash-handle prop model was found this pass. There is no
    -- native-decls-equivalent registry of PROP MODEL NAMES to check the way
    -- there is for natives -- a model's existence can only be confirmed
    -- empirically against a live client, which this pass did not have.
    -- Survivable by design: fallbackPropModel below is the SAME
    -- confirmed-safe placeholder this resource already uses elsewhere
    -- (Config.PropAttachments.fallbackPropModel / Config.DeployableKennel's
    -- own fallback) specifically because an obviously-wrong prop tells an
    -- operator to go find a real one, where a silent no-op would just look
    -- like the feature is broken.
    handleModel = 'p_ing_dogleash01x', -- UNVERIFIED GUESS, not sourced from any confirmed model list -- replace with a real leash-handle prop once one is found
    handleFallbackModel = 'prop_tennis_ball',
}

-- ======================================================================
-- NOTE (coder-architect, Phase 1 rewrite): Config.K9DespawnGraceSeconds
-- was added in the first scaffolding pass for a handler->K9 netId
-- registry that no longer exists — DEVELOPER_REFERENCE.md's post-draft correction
-- established the K9 is a player's own persistent character (§1, §4.5),
-- with no spawn/despawn/registry concept at all. Removed; do not re-add
-- without a new documented reason, since nothing currently consumes it.
-- ======================================================================

-- ======================================================================
-- XP TIERS — Phase 4, placeholder numbers pending economy-balance-agent review
-- ======================================================================
Config.XPTiers = {
    -- scentRangeMultiplier REPLACED the old absolute `scentRange` field, and
    -- the unit changed, which is why the name had to change with it. The old
    -- values (5.0/6.5/8.0/10.0) were applied as a math.max FLOOR against each
    -- track type's own maxRange -- and every maxRange defaults to 40.0. Even
    -- the Elite tier's 10.0 could never exceed 40.0, so the floor could never
    -- raise anything, for any tier. "Scent range grows with XP" was numerically
    -- dead from the day it shipped.
    -- Now a multiplier over each track type's own maxRange, so it scales with
    -- whatever that type is tuned to instead of fighting an absolute ceiling.
    -- Base tier is 1.00 = no bonus, so a base-tier K9's range is byte-identical
    -- to today's behaviour. Only a value > 1.0 does anything.
    -- Pure balance placeholders -- tune freely.
    -- RETUNED 2026-08-25 from 500/1500/3500, on measured extraction rates
    -- rather than feel. The old top tier was reachable in about 49 minutes
    -- of nonstop optimal play once the combat awards ship, and in roughly
    -- 2.3 hours using only what is closest to shippable today -- an
    -- evening, not the weeks of K9 duty the progression is meant to
    -- represent.
    --
    -- New thresholds keep the old proportions (14% / 44% / 100% of top).
    -- At a realistic legitimate rate of ~500 XP/hr, Elite takes about 18
    -- hours total, or roughly 2 to 2.5 weeks at an hour or so a day.
    --
    -- WORST-CASE FARMABLE CEILING, recomputed 2026-08-25. The figure that
    -- used to sit here (4320 XP/hr) was wrong, because it reasoned about
    -- the combat awards in isolation. Each of the four XP mechanics had its
    -- own independent mint cooldown, and nobody had ever summed them:
    --     bite-hold      60s / 20 XP  -> 1,200/hr
    --     takedown       60s / 30 XP  -> 1,800/hr
    --     contraband     60s / 25 XP  -> 1,500/hr
    --     track resolved 30s / 10 XP  -> 1,200/hr
    -- Round-robining all four came to 5,700 XP/hr, putting Elite at about
    -- 1h35m -- under the "over 2 hours" floor these tiers were retuned to
    -- guarantee. Worse, none of it required real police work: an ambient,
    -- non-wanted pedestrian qualified for both combat awards.
    --
    -- Closed by a shared cross-mechanic mint budget in server/progression's
    -- AwardXP (a per-citizenid token bucket, 3600 XP per rolling hour) plus
    -- Config.XP.mintXpForNpcCombatTargets defaulting off. The four
    -- per-mechanic cooldowns still decide WHICH mechanic may mint; the
    -- budget caps the TOTAL. Real ceiling is now 3,600 XP/hr:
    --     Trained (1,250)  ~18m
    --     Veteran (4,000)  ~1h 04m
    --     Elite   (9,000)  ~2h 27m   -- clears the floor with ~27m to spare
    --
    -- Deliberately NOT the order-of-magnitude raise floated earlier. That
    -- figure was anchored to the ~9000 XP/hr contraband farm, which is now
    -- closed; reapplying it against the corrected ceiling would overshoot.
    { xp = 0,    label = 'Recruit K9', speedMultiplier = 1.00, scentRangeMultiplier = 1.00 },
    { xp = 1250, label = 'Trained K9', speedMultiplier = 1.05, scentRangeMultiplier = 1.05 },
    -- Veteran unlocks a shorter K9 medkit cooldown. A multiplier, not an
    -- absolute: 0.75 means "three quarters of the configured wait".
    -- Deliberately a NUMBER and never a boolean -- it is consulted only
    -- AFTER an existing gate has already allowed the action, so reaching a
    -- tier can shorten a wait but can never grant access to anything.
    { xp = 4000, label = 'Veteran K9', speedMultiplier = 1.10, scentRangeMultiplier = 1.10, medkitCooldownMultiplier = 0.75 },
    -- Elite gets a cosmetic HUD badge. Display only, no mechanical effect.
    { xp = 9000, label = 'Elite K9',   speedMultiplier = 1.15, scentRangeMultiplier = 1.20, badge = 'elite' },
}

-- ======================================================================
-- HANDLER XP TIERS (Config.Features.HandlerXPProgression,
-- server/progression.lua's AwardHandlerXP/GetHandlerXPTier). The owner's
-- own ask: a "partners and levels" tablet tab for BOTH K9s and handlers.
-- Config.XPTiers above already answers the K9 half; this is the handler
-- half.
--
-- WHY A SEPARATE LADDER, NOT A SECOND READING OF Config.XPTiers: every
-- effect on Config.XPTiers (speedMultiplier/scentRangeMultiplier/
-- medkitCooldownMultiplier) acts on a K9's own ped -- meaningless applied
-- to a human handler. Rather than invent effects for a handler on the SAME
-- ladder (which would also mean a K9's own combat/search grinding
-- silently unlocked handler perks, and a handler's own certifying/treating
-- silently unlocked K9 speed/scent, for the SAME citizenid across two
-- unrelated skill tracks -- see Config.HandlerXP's own header for why that
-- was rejected), this is its own ladder, fed by its own
-- Config.HandlerXP.awards table, walked the identical way
-- server/progression.lua's ResolveTier already walks Config.XPTiers
-- (ascending, first entry MUST be xp = 0 -- same mandatory baseline
-- contract).
--
-- STILL ONE ROW PER CITIZENID, NOT A SECOND k9_progression-shaped TABLE:
-- persisted as `k9_progression.handler_xp`, a second column on the SAME
-- row XPTiers' own total (`xp`) already lives on -- see
-- sql/migrations/0017_add_k9_progression_handler_xp.sql's own header for
-- the full schema reasoning. One citizenid, one row, TWO independent
-- totals -- a person who is sometimes the K9 and sometimes the handler
-- keeps two separate standings, each earned only by that role's own
-- actions, rather than one shared number blending unrelated skill tracks.
--
-- EVERY EFFECT FIELD BELOW IS INTENDED TO BE OPTIONAL AND DEFENSIVELY
-- BOUNDED, same "consulted only after an existing gate has already allowed
-- the action, can only ever shorten a wait or lengthen a distance, never
-- grant access" posture Config.XPTiers' own medkitCooldownMultiplier
-- already established for the K9 side (GetXPTierMedkitCooldownMs,
-- server/progression.lua).
--
-- DEAD-CONFIG-FIELD AUDIT RESOLUTION (coder-backend, this pass; supersedes
-- the "None of that exists" correction that used to sit in this exact spot
-- -- that correction was accurate when written and is now itself stale,
-- exactly the trap this resource's "note at the field, not a thousand
-- lines away" rule exists to prevent): a full audit found these three
-- fields genuinely unread, named the three missing accessors that would
-- need to exist, and required each to be either wired or removed --
-- "known and disclosed" is not an acceptable third state. Resolution,
-- field by field:
--   * medkitTreatCooldownMultiplier -- WIRED. GetHandlerXPTierMedkitCooldownMs
--     (server/progression.lua) now exists and is consulted by
--     server/medkit.lua's RunUseK9MedkitMutation, keyed on the USING
--     player's own citizenid, chained on top of Config.XPTiers' own
--     medkitCooldownMultiplier (the TARGET K9's tier) rather than
--     replacing it -- a high-tier handler treating a high-tier K9 gets
--     both reductions at once.
--   * kennelDeployCooldownMultiplier -- WIRED. GetHandlerXPTierKennelDeployCooldownMs
--     (server/progression.lua) now exists and is consulted by
--     server/kennel.lua's requestDeployKennel handler, keyed on the
--     deploying handler's own citizenid (the same identity DeployCooldown
--     itself is already keyed by, unlike the medkit case above).
--   * leashRangeMultiplier -- REMOVED, not wired (this pass judged wiring
--     it more than a small, safe change -- pulled rather than left half
--     done). Config.LeashMaxDistance is consulted as a raw, shared
--     constant in at least four places across three files today
--     (server/main.lua's CheckLeashEligibility attach-time proximity
--     check; client/movement.lua's LEASH_PULL_ZONE_FACTOR/
--     LEASH_HARD_CAP_FACTOR elastic-constraint math, which actually
--     enforces the leash mechanically once attached; client/leashvisual.lua's
--     rope max-length; client/radial.lua's pre-attach candidate search),
--     with NO per-citizenid channel anywhere in that chain -- server/main.lua's
--     own header explicitly documents reusing the raw base value at
--     attach time as deliberate. Wiring a per-handler bonus correctly
--     would mean threading a brand-new value through the leash
--     consent-handshake payload AND updating the live elastic-constraint
--     math in client/movement.lua to match (an attach that succeeds at a
--     rank-widened range but is then immediately "pulled back" by a
--     client unaware of that widening is the exact half-wire this
--     resource's own rule forbids), deciding WHICH of the two leashed
--     parties' rank should apply, and deciding whether a mid-session rank-up
--     needs a live re-push the way Config.XPTiers' own PushTierSnapshot
--     gives the K9 side. Real design work, not an accessor to mirror --
--     if this is reintroduced later, do that work in full rather than
--     bolting a multiplier onto the existing raw-constant reads.
--
-- FEEDBACK-LOOP SAFETY CHECKED BEFORE WIRING EITHER COOLDOWN MULTIPLIER
-- (both shorten the cooldown on an action Config.HandlerXP.awards also
-- prices -- handlerTreatK9 for medkit, handlerKennelDeploy for kennel
-- deploy -- so a rank that shortens either could, in principle, make the
-- ladder faster to climb the higher you climb it): NO LOOP EXISTS TODAY,
-- because AwardHandlerXP is called from nowhere for either actionKey (see
-- this file's own Config.Features.HandlerXPProgression header, "DELIBERATELY
-- LEFT UNWIRED", for the full reasoning and arithmetic). THIS COOLDOWN
-- REDUCTION MUST BE ACCOUNTED FOR THE DAY EITHER AWARD IS WIRED, THOUGH --
-- see server/progression.lua's own doc comment on
-- GetHandlerXPTierMedkitCooldownMs/GetHandlerXPTierKennelDeployCooldownMs
-- ("HANDLER XP TIER UNLOCKS" section) for the exact rank-reduced worst-case
-- numbers (31500ms combined medkit floor, 3000ms kennel-deploy floor) and
-- the binding requirement (a dedicated per-actor mint cooldown, sized
-- against THOSE numbers, never derived from MedkitCooldown/DeployCooldown
-- itself). tests/medkit_spec.lua and tests/kennel_spec.lua each carry a
-- SOURCE AUDIT test that fails outright if either award is ever wired
-- without that companion mint cooldown also present.
--
-- UNREVIEWED PLACEHOLDER NUMBERS, same status Config.XPTiers/Config.XP
-- carry -- tune freely once a real handler-XP economy pass happens.
-- Cumulative by design (each tier restates every lower tier's own bonus
-- fields plus its own new one) so a handler's benefits only ever grow with
-- rank, never drop out at a higher tier the way Config.XPTiers' own Elite
-- row currently omits medkitCooldownMultiplier (an existing, pre-dating
-- inconsistency on the K9 ladder this pass observed but does not touch --
-- flagged for whoever owns that table's own tuning next).
Config.HandlerXPTiers = {
    { xp = 0,    label = 'Rookie Handler' },
    -- medkitTreatCooldownMultiplier -- WIRED (server/medkit.lua, via
    -- GetHandlerXPTierMedkitCooldownMs). See this table's own header above
    -- for the full field-by-field resolution and the feedback-loop
    -- safety note.
    { xp = 750,  label = 'Certified Handler', medkitTreatCooldownMultiplier = 0.90 },
    -- kennelDeployCooldownMultiplier -- WIRED (server/kennel.lua, via
    -- GetHandlerXPTierKennelDeployCooldownMs). Same header, same note.
    { xp = 2500, label = 'Senior Handler',    medkitTreatCooldownMultiplier = 0.80, kennelDeployCooldownMultiplier = 0.75 },
    -- Master Handler's own combined worst-case floors (both cooldowns
    -- stack with any lower tier already earned, by design -- see "cumulative
    -- by design" above): medkit 60000ms * 0.70 = 42000ms alone, 31500ms
    -- combined with a Veteran-tier K9 TARGET's own 0.75 (Config.XPTiers);
    -- kennel deploy 5000ms * 0.60 = 3000ms. These are the exact numbers
    -- server/progression.lua's own doc comment and the SOURCE AUDIT tests
    -- above cite -- if you retune either multiplier here, that comment and
    -- those tests go stale and need updating too.
    { xp = 6000, label = 'Master Handler',    medkitTreatCooldownMultiplier = 0.70, kennelDeployCooldownMultiplier = 0.60 },
}

-- ======================================================================
-- XP PROGRESSION (Config.Features.XPProgression, server/progression.lua).
-- Per-action award VALUES that accumulate toward Config.XPTiers' thresholds
-- above (that table was drafted early and sat unused until this pass).
-- DEVELOPER_REFERENCE.md §13.4.1 — the exact award-action list (searchContrabandFound/
-- trackSourceResolved/biteHoldSuccess/takedownSuccess) is taken verbatim from
-- that section, not invented here. Every value below is an unreviewed
-- placeholder pending economy-balance-agent/config-validator review
-- (DEVELOPER_REFERENCE.md §9 item 4), same status Config.XPTiers itself already carries.
-- ======================================================================
Config.XP = {
    -- Whether an NPC bite-hold or takedown target MINTS XP. Defaults false.
    --
    -- This does NOT change whether NPC combat is allowed -- that is a
    -- separate, settled decision and this key does not touch it. It only
    -- decides whether an NPC target PAYS.
    --
    -- Why it defaults off: Config.Combat.RequireWantedStatus applies to
    -- player targets only, so with this on, any ambient pedestrian
    -- qualified for both combat awards. That made the largest share of the
    -- farmable XP ceiling reachable with no police work at all -- provoke a
    -- passer-by into running and take them down, on repeat. Turning it on
    -- is a legitimate choice for a server that wants NPC K9 work to
    -- progress a handler; just know it is the single biggest lever on how
    -- fast XP can be farmed without doing anything real.
    mintXpForNpcCombatTargets = false,

    awards = {
        -- server/search.lua's HandleSearchTarget, at the point
        -- `contrabandFound == true` is already known (existing Phase 2
        -- success path — this is a new CONSUMER of that outcome, no change
        -- to search.lua's own validation order/cooldowns).
        searchContrabandFound = 25,
        -- server/tracking.lua's findTrackableSource resolving `found = true`
        -- is NOT, by itself, the award trigger — see trackArrivalRadius/
        -- trackArrivalTTLMs below. DEVELOPER_REFERENCE.md §13.4.1 open question 3
        -- explicitly flags that awarding on `found = true` alone lets a K9
        -- farm XP by repeatedly triggering a search without ever completing
        -- it; this implementation closes that by requiring the K9's own
        -- client to subsequently arrive within trackArrivalRadius of the
        -- SERVER's resolved coordinate before this amount is granted.
        trackSourceResolved   = 10,
        -- server/combat.lua's requestBiteHold success (DEVELOPER_REFERENCE.md
        -- §12.5.1). WIRED. The note that stood here -- "NOT YET WIRED:
        -- server/combat.lua does not exist in this codebase" -- predated
        -- Phase 3 combat landing and had gone stale; that file exists and
        -- calls AwardXP(citizenid, 'biteHoldSuccess') from its success
        -- path. See server/progression.lua's header for the call contract.
        biteHoldSuccess       = 20,
        -- server/combat.lua's requestTakedown success (DEVELOPER_REFERENCE.md
        -- §12.5.2) -- same stale-note correction as biteHoldSuccess above;
        -- this one is wired too.
        takedownSuccess       = 30,
        -- server/sarcalls.lua, on a genuine find only -- never on a timeout
        -- or an abandon. THE ARITHMETIC: the 10-minute per-person cooldown
        -- on REQUESTING a call caps this at six completions an hour, so
        -- 6 x 30 = 180 XP/hr is the most this feature can add, well under
        -- the shared 3,600 XP/hr budget it still draws from. The 40-metre
        -- minimum placement distance is the other half of the defence:
        -- it guarantees real travel no matter how fast calls are repeated.
        sarCallCompleted      = 30,
        -- server/search.lua, awarded to a partnered handler/K9 who was
        -- ONLINE and physically within 15m of the search TARGET's own
        -- coordinates (not the searcher's) when a contraband find landed,
        -- with both parties at Trained tier or above. Minted through the
        -- same AwardXP chokepoint as everything else, so it draws on the
        -- shared 3,600 XP/hr budget rather than adding to it.
        --
        -- THE ARITHMETIC, because this codebase has closed eight XP farms
        -- and every new award has to show its working: uncapped, a 60s
        -- per-receiving-partner cooldown at 10 XP is 600 XP/hr, which
        -- pushes the uncapped five-mechanic sum to 6,300 XP/hr -- over the
        -- budget, which is exactly why it must route through it and does.
        -- Simulated as a fifth competing draw over a real hour, the total
        -- came to 3,665 XP, LOWER than the four-mechanic figure of 3,810:
        -- more demand divides a fixed supply, it does not enlarge it.
        -- Elite is still unreached at the two-hour mark.
        coopSearchBonus       = 10,

        -- server/tenure.lua's partnership-tenure milestones. Each is a
        -- ONE-TIME award per partnership row -- never repeating, never
        -- per-tick. That distinction is the whole safety argument: this is
        -- the only award in this table driven by a WALL CLOCK rather than a
        -- player action, so a recurring trickle would be a pure idle-XP
        -- farm. The hard cap (15+40+100 = 155 XP ever, per partnership) is
        -- what makes awarding from a non-activity-gated clock safe at all.
        -- UNTUNED PLACEHOLDERS, same review status as every other value
        -- here. For scale: the top XP tier is reached at 3500.
        partnershipTenure1Day  = 15,  -- 24 real-world hours of continuous active partnership
        partnershipTenure7Day  = 40,  -- 7 days
        partnershipTenure30Day = 100, -- 30 days
    },

    -- 'citizenid' (default, per DEVELOPER_REFERENCE.md §13.2's own default and
    -- DEVELOPER_REFERENCE.md#xp-schema §4's schema sketch, which
    -- assumes this): XP belongs to the K9 character itself and is portable
    -- across a department change (k9_progression is keyed by citizenid
    -- alone, no job column). 'job' would need a composite (citizenid, job)
    -- primary key instead, mirroring k9_certifications — NOT implemented by
    -- this pass; DEVELOPER_REFERENCE.md §13.6 item 2 flags this as a genuinely open
    -- product call still needing explicit sign-off. Left at the documented
    -- default rather than silently guessed differently.
    scopePerCitizenidOrJob = 'citizenid',

    -- EXTENSION beyond DEVELOPER_REFERENCE.md §13.2's own sketch (that section only
    -- specified `awards`/`scopePerCitizenidOrJob`) — added to actually
    -- resolve open question 3 above rather than leave the farm exploit it
    -- flags unresolved. The `findTrackableSource` reveal itself stays
    -- purely client-cosmetic (no XP consequence at that point, per §11.6);
    -- `trackSourceResolved` XP is only granted once the K9's own client
    -- reports arrival within this radius of the coordinate the SERVER
    -- resolved — server/tracking.lua re-measures live distance itself
    -- against its own server-held pending-arrival state, never a
    -- client-supplied coordinate or distance claim.
    trackArrivalRadius = 3.0,    -- meters
    trackArrivalTTLMs  = 60000,  -- how long a resolved-but-unreached source stays eligible for a late arrival report before expiring — prevents a stale pending-arrival slot from awarding XP for a long-abandoned search
}

-- ======================================================================
-- HANDLER XP PROGRESSION (Config.Features.HandlerXPProgression,
-- server/progression.lua's AwardHandlerXP). Config.XP above pays the K9
-- for K9-mechanical actions (search/track/bite/takedown/wall-clock
-- tenure); this pays the HANDLER for handler actions -- into a SEPARATE
-- accumulated total (`k9_progression.handler_xp`), walked against the
-- SEPARATE Config.HandlerXPTiers ladder above.
--
-- WHAT COUNTS AS A HANDLER ACTION, and why each one is safe to pay for --
-- chosen from what this codebase can actually observe server-side today,
-- never an invented event:
--   * handlerCertifyK9 -- server/certifications.lua's GrantCertification (and
--     GrantCertificationOffline), at the point a NEW (not renewed/
--     already-active) certification is granted. NOT, on its own, "rare and
--     deliberate by nature" the way this bullet used to claim: a genuine
--     revoke-then-regrant cycle is exactly the ordinary lifecycle this
--     resource supports (RevokeCertification followed by GrantCertification
--     for the same citizenid+job is not an edge case), and with
--     Config.AllowSelfCertification true by default an eligible certifier
--     can run that cycle against THEMSELVES with no accomplice at all --
--     found live by an economy audit (2026-08-26) as this table's single
--     worst farm loop, well past what handlerKennelDeploy/handlerTreatK9
--     below were already rejected for. What actually makes this safe to pay
--     is CertifyXpMintCooldown (server/certifications.lua) -- a dedicated
--     per-(granter, target) MINT cooldown, 24 real hours, gating the AWARD
--     itself (never the grant/revoke action, which always succeeds
--     regardless) -- added by that same audit. It is still the highest
--     single award here, but because a genuinely NEW target pays
--     immediately while the SAME (granter, target) pair cannot pay again
--     for a day, not because repeating it was already hard.
--   * handlerTreatK9 -- server/medkit.lua's RunUseK9MedkitMutation, paid to
--     the USING player (never the K9 being healed) on a genuine injury
--     restore. Bounded today by that file's own per-TARGET MedkitCooldown
--     (Config.K9Medkit.cooldownMs, 60000ms default) and by a real injury
--     needing to exist first -- NOT YET bounded by any per-ACTOR cooldown,
--     so a handler roaming between several simultaneously-injured K9s has
--     no throttle of their own yet. See Config.Features.HandlerXPProgression's
--     own comment above for why this keeps the feature off by default
--     until that lands.
--   * handlerKennelDeploy -- server/kennel.lua's deploy/pickup success
--     path. Bounded ONLY by that file's own per-actor DeployCooldown
--     (Config.DeployableKennel.deployCooldownMs, 5000ms default) today --
--     see Config.Features.HandlerXPProgression's own comment above for the
--     measured 5,760 XP/hr worst case this implies without a dedicated
--     mint cooldown, and why this feature ships off until one exists.
--   * handlerPartnershipTenure{1,7,30}Day -- paid to `handler_citizenid`
--     by the SAME milestone-crossing check server/tenure.lua already runs
--     for the K9 side (Config.Partnership.TenureBonus.milestones' own
--     `handlerActionKey` field below) -- inherits that mechanism's
--     existing one-time-per-partnership-row CAS guard and same-pair-reform
--     seeding for free, no new anti-farm needed. WIRED (issue-closer sweep,
--     2026-08-26): this bullet used to say "NOT YET WIRED -- server/tenure.lua
--     is not edited by this pass" -- stale, since corrected at that field's
--     own declaration comment (Config.Partnership.TenureBonus.milestones,
--     below, search for "dead-config-field audit correction"). Verified
--     directly in server/tenure.lua's CheckTenureMilestonesForK9: its
--     milestone-crossing loop calls `AwardHandlerXP(row.handler_citizenid,
--     milestone.handlerActionKey)` right after paying the K9 side, so all
--     three of these keys are live today, not merely planned.
--   * "present for a successful search/track" is DELIBERATELY NOT
--     duplicated here -- server/search.lua's existing coopSearchBonus
--     (Config.XP.awards above) already pays a present, Trained+ partner
--     (which may already be a handler citizenid) through the ORIGINAL
--     shared `xp` column, exactly as it does today. Re-routing that
--     already-shipped, already-tested award into this SEPARATE handler
--     total was considered and rejected: it is one of only two role-
--     agnostic exceptions this design intentionally leaves alone (the
--     other being /k9givexp's AwardXPDirect) -- see server/progression.lua's
--     AwardHandlerXP doc comment for the full "why not touch these two"
--     reasoning.
--
-- ANTI-FARM: every award below is minted through AwardHandlerXP, which
-- reuses (never duplicates) server/progression.lua's existing
-- per-(citizenid, actionKey) 500ms rate floor AND its shared,
-- cross-mechanic XP mint budget (3,600 XP per rolling hour, PER CITIZENID,
-- SHARED with Config.XP.awards above -- a citizenid farming both totals at
-- once still only ever mints 3,600 XP/hr combined, never 3,600 of each).
-- See server/progression.lua's own AwardHandlerXP doc comment for the full
-- per-award-path anti-farm accounting (repeat-cheapest-action,
-- accomplice-trading, break/reform-partnership, and relog, each answered).
--
-- UNREVIEWED PLACEHOLDER VALUES, same status as every number in Config.XP
-- above.
-- ======================================================================
Config.HandlerXP = {
    awards = {
        handlerCertifyK9              = 50,
        handlerTreatK9                = 12,
        handlerKennelDeploy           = 8,
        handlerPartnershipTenure1Day  = 15,
        handlerPartnershipTenure7Day  = 40,
        handlerPartnershipTenure30Day = 100,
    },
}

-- ======================================================================
-- CONTRABAND ALERT THRESHOLDS — Phase 2, placeholder pending
-- config-validator/economy review against actual ox_inventory item weights.
-- Order matters: server/search.lua walks this list and keeps the LAST tier
-- whose minWeight the total contraband weight meets or exceeds, so entries
-- must stay sorted ascending by minWeight. The 'clean' baseline is
-- mandatory (DEVELOPER_REFERENCE.md §11.4) so a zero-contraband result always resolves to
-- a real tier instead of falling through unhandled.
-- ======================================================================
Config.ContrabandAlertTiers = {
    { minWeight = 0,   alert = 'clean' },           -- nothing found / below any threshold
    { minWeight = 1,   alert = 'whine' },           -- small personal-use amount
    { minWeight = 250, alert = 'aggressive_bark' }, -- large stash
}

-- ======================================================================
-- FIND ALERTS (Config.Features.FindAlerts) -- PROJECT_HISTORY.md §1. A reaction
-- layer over the tier names Config.ContrabandAlertTiers above already
-- defines. It adds no new tiers; it only says how the SEARCHING K9's own
-- character should react to each existing one.
--
-- THERE IS DELIBERATELY NO 'clean' ROW, and that is not an oversight. A
-- real detection dog's trained final response only fires on a genuine
-- positive. A tier with no row here -- 'clean', or any new tier you add to
-- Config.ContrabandAlertTiers above without adding a row here -- means "no
-- automatic reaction". It fails closed to silence; it never guesses.
--
-- `sit` plays the same sit animation the manual Sit radial option uses.
-- `sound` is a sound name, and both below resolve to a real file that
-- actually ships (html/sounds/bark_alert.ogg and bark_aggressive.ogg). A
-- sound name with no file behind it degrades to silence, which looks
-- exactly like the feature being switched off -- so if you change these,
-- check html/sounds/ for what is actually there.
-- ======================================================================
Config.FindAlerts = {
    reactionsByAlertTier = {
        whine           = { sit = true, sound = 'Bark_Alert' },
        aggressive_bark = { sit = true, sound = 'Bark_Aggressive' },
    },

    -- Also react when the K9 reaches the end of a scent, blood or gunpowder
    -- trail, with the same strength as a big find.
    --
    -- ONE HONEST LIMITATION: the event this listens for is only fired while
    -- Config.Features.XPProgression is ALSO on, because it lives inside
    -- that flag's own check for an unrelated reason. So with XPProgression
    -- off, this particular bonus stays silent even with tracking and
    -- FindAlerts both on. The contraband-search reaction above is
    -- unaffected and works either way.
    reactOnTrackArrival = true,
}

-- ======================================================================
-- TRACKING (scent / blood / gunpowder). Ranges in meters, ages/
-- time windows in seconds. Each trail TYPE is independently gated by its
-- own Config.Features flag (ScentTracking / BloodTracking /
-- GunpowderSniffing) — these tuning tables only take effect for whichever
-- types are enabled; read at the point of use (search command execution),
-- not cached at resource start, per §3's acceptance criteria applied here.
-- ======================================================================
Config.Tracking = {
    Scent = {
        maxRange         = 40.0,  -- max distance from the K9's current position to a valid scent source at search time
        maxAgeSeconds    = 900,   -- how long a dropped item stays trackable as a scent source (§9 item 17 close-out, 2026-08-23). Deliberately longer than Blood/Gunpowder's 300s/120s -- a physical dropped item sitting on the ground doesn't decay the way a damage/gunfire event does. Judgment call, not independently confirmed against real gameplay balance -- DEVELOPER_REFERENCE.md#scent-source-resolution §4 flags this as worth a product-manager/config-validator/economy-balance-agent pass; revisit if playtesting says otherwise.
        markerSpacing    = 3.0,   -- meters between rendered trail markers/checkpoints
        searchCooldownMs = 5000,  -- per-player cooldown on re-issuing a "search" command of this type
        relayCooldownMs  = 1000,  -- per-dropping-player cap on how often the ox_inventory 'swapItems' hook (server/tracking.lua) logs a new scent-source entry. UNLIKE Blood/Gunpowder's field of the same name, this is NOT closing an anti-forgery gap -- the hook is server-to-server, so `payload.source` cannot be spoofed to claim a drop that didn't happen. It's defense-in-depth against a rapid drop/pickup/drop loop growing the server-side scent log unbounded between prune passes. Placeholder pending tuning.

        -- HARD CEILING on the total number of scent entries held in memory
        -- AT ONCE, across every player combined -- completely independent
        -- of maxAgeSeconds above. maxAgeSeconds only ever throws away an
        -- entry once it gets OLD; it says nothing about how many can pile
        -- up before then. The arithmetic, worked from this table's own
        -- numbers: relayCooldownMs (1000ms) lets one dropping player add at
        -- most one entry per second, and maxAgeSeconds (900s) keeps each
        -- one around for 15 minutes -- so ONE player sustaining that rate
        -- for the entire window logs up to 900 entries
        -- (900,000ms / 1000ms). At 128 players doing that at once -- a
        -- genuinely normal busy evening of full-server activity, not an
        -- attack -- that is up to 115,200 entries in this table alone.
        -- Once the log hits this many entries, adding a new one drops the
        -- OLDEST entry to make room (never the newest -- a dog is most
        -- likely to be tracking whatever was JUST logged). 6,000 is
        -- deliberately generous: it holds roughly 6-7 players' worth of
        -- continuous worst-case dropping for the ENTIRE 15-minute window,
        -- all at once, which is already far beyond what real play produces
        -- (nobody drops and picks an item back up once a second, nonstop,
        -- for 15 minutes). Raise it if your server is bigger than 128 slots
        -- or busier than this -- there is no reason to lower it on a normal
        -- server.
        maxLoggedEntries = 6000,
    },
    Blood = {
        maxRange         = 40.0,
        maxAgeSeconds    = 300,   -- damage events older than this are no longer trackable (pruned from the server-side log, §11.4)
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
        relayCooldownMs  = 500,   -- per-victim cap on how often relayDamageEvent may log a new entry — distinct from searchCooldownMs (a query-side cooldown); guards the ingest side against a flood of legitimate rapid hits (multiple pellets/DoT ticks) or a modified client bypassing the client-side debounce. Placeholder pending an economy/perf tuning pass.

        -- HARD CEILING, same idea as Scent.maxLoggedEntries above -- read
        -- that field's own comment first for the full "why this exists and
        -- why eviction takes the oldest entry" explanation; only the
        -- arithmetic differs here. At this table's own relayCooldownMs
        -- (500ms) and maxAgeSeconds (300s), one continuously-bleeding
        -- player can log up to 600 entries (300,000ms / 500ms) before their
        -- own oldest one ages out. At 128 players doing that simultaneously
        -- -- a genuinely normal, busy full-server firefight, not an
        -- adversarial edge case -- that is up to 76,800 entries in this
        -- table alone (this is the largest of the three worst cases,
        -- because Blood has both the shortest relayCooldownMs and a longer
        -- window than Gunpowder). 8,000 is deliberately generous: it holds
        -- roughly 13 players' worth of continuous worst-case bleeding for
        -- the ENTIRE 5-minute window all at once -- a genuinely enormous,
        -- sustained multi-officer firefight -- while still cutting this
        -- table's own worst-case memory footprint from tens of megabytes
        -- down to roughly 1-2MB. Raise it for a bigger/busier server; there
        -- is no reason to lower it on a normal one.
        maxLoggedEntries = 8000,
    },
    Gunpowder = {
        maxRange         = 40.0,
        maxAgeSeconds    = 120,   -- shorter window than blood -- residue is time-sensitive
        markerSpacing    = 3.0,
        searchCooldownMs = 5000,
        relayCooldownMs  = 300,   -- per-shooter cap on how often relayWeaponFire may log a new entry, same rationale as Blood.relayCooldownMs above. Placeholder pending tuning.

        -- HARD CEILING, same idea as Scent.maxLoggedEntries/Blood.maxLoggedEntries
        -- above -- read Scent's own comment first for the full "why this
        -- exists and why eviction takes the oldest entry" explanation. At
        -- this table's own relayCooldownMs (300ms) and maxAgeSeconds
        -- (120s), one continuously-firing player can log up to 400 entries
        -- (120,000ms / 300ms) before their own oldest one ages out. At 128
        -- players doing that simultaneously -- again, a normal busy
        -- server's full-scale shootout, not an attack -- that is up to
        -- 51,200 entries in this table alone. 6,000 is deliberately
        -- generous: it holds roughly 15 players' worth of continuous
        -- worst-case firing for the ENTIRE 2-minute window all at once,
        -- while cutting this table's own worst-case memory footprint from
        -- several megabytes down to roughly 1MB. Raise it for a
        -- bigger/busier server; there is no reason to lower it on a normal
        -- one.
        --
        -- Combined with Scent's and Blood's own ceilings above, these three
        -- caps bring the resource-wide worst case for ALL THREE logs
        -- together down from roughly 243,000 entries / 35-50MB
        -- (uncapped, at 128 players sustaining every type at once) to
        -- 20,000 entries / roughly 3-4MB -- still by far the largest
        -- in-memory structure this resource holds, but no longer an
        -- unbounded one.
        maxLoggedEntries = 6000,
    },

    -- ==================================================================
    -- ScentVision (Config.Features.ScentVision). See that flag's own
    -- comment above for the feature summary. SERVER-SIDE (server/tracking.lua),
    -- every one of these is read fresh at the point of use (never captured
    -- once at load) -- a config edit there takes effect on the very next
    -- capture pass/query, no restart needed, matching this resource's
    -- DEVELOPER_REFERENCE.md §3 convention. Non-positive *Ms/*Meters values are never
    -- read as "forever"/"unlimited" -- they are clamped to a safe built-in
    -- default with a loud one-time warning naming the bad field, the same
    -- ResolveConfiguredThresholdMs discipline server/cooldowns.lua
    -- documents and this resource applies everywhere a millisecond
    -- threshold is read out of an operator-editable Config field.
    --
    -- CLIENT-SIDE EXCEPTION, DISCLOSED (qa-tester finding): `pollIntervalMs`
    -- and `fadeStartFraction` are resolved ONCE, at client/tracking.lua's own
    -- file-load time, into a local constant -- NOT re-read on every poll or
    -- every frame. This does not contradict the "live, no restart" claim
    -- above in practice TODAY: this codebase has no mechanism anywhere to
    -- push a live config value to an ALREADY-CONNECTED client at all (every
    -- client loads its own independent copy of this shared_script once, at
    -- its own resource start) -- so a client-side value already requires
    -- that client to reconnect/the resource to restart for ANY edit to reach
    -- it, identically to every other client-only Config field in this
    -- resource (see server/runtimecontrol.lua's own `tier = 'clientonly'`
    -- classification for the general shape of this same gap). Flagged
    -- explicitly so this stops being an implicit assumption the moment a
    -- future pass ever adds live client-config push: `fadeEnabled` and the
    -- 45000ms dot-lifetime CLIENT-SIDE FALLBACK default (used only until the
    -- first server response arrives, which always echoes back the lifetime
    -- it actually enforced) share this same "resolved once, client-only"
    -- shape, for the identical reason. `mode` (below) is the SAME shape for
    -- STARTING/becoming eligible for 'always' -- an admin flipping
    -- 'keybind' to 'always' on config.lua does not retroactively start
    -- rendering for a player already connected before the next restart --
    -- but is the ONE EXCEPTION for STOPPING: server/tracking.lua's own
    -- getScentVisionPoints echoes the server's live-resolved `mode` (and an
    -- outright Config.Features.ScentVision = false) on every poll response
    -- already in flight, and client/tracking.lua treats either as an
    -- immediate, unconditional stop -- never gated behind this file's own
    -- client-side `mode` copy -- so a currently-rendering player's screen
    -- always clears the moment the server says to, restart or not. See
    -- `mode`'s own comment below for why that asymmetry (start needs a
    -- restart, stop never does) is deliberate, not an oversight.
    -- ==================================================================
    ScentVision = {
        -- CAPTURE (server/tracking.lua's position-sampling thread):
        sampleIntervalMs        = 4000, -- how often EACH connected player's own live position is sampled into their own trail. Lower = a denser, more continuous-looking trail at a higher per-tick native-call cost across the whole population; higher = cheaper but coarser. 4s at typical on-foot speed spaces dots a few metres apart, matching the "well-spaced dots, not a photograph of every footstep" brief.
        minSampleMovementMeters  = 2.0, -- a new point is only recorded if the player has moved at least this far since their OWN last recorded point -- keeps a stationary/AFK player from stacking redundant, visually-overlapping dots at one spot.
        maxPointsPerPerson       = 15,  -- hard per-person ring-buffer ceiling, enforced on every capture (oldest evicted first) independent of the age-based expiry below -- this is the real worst-case bound the memory math in this pass's own report is computed from; a misconfigured tiny sampleIntervalMs can never exceed it.
        dotLifetimeMs            = 45000, -- EACH DOT'S OWN age-out timer (45s shipped default), timestamped at the moment that specific dot was recorded -- never a single timer for the whole trail. The oldest dot vanishes first; the trail's remaining length is itself the "how long ago did they pass" signal. Non-positive is refused (never "forever") -- see this table's own header note above.
        fadeEnabled              = true,  -- true: a dot's opacity ramps down to 0 over the tail end of its own dotLifetimeMs rather than blinking out; false: full opacity until the instant it expires, then gone. Client-only cosmetic -- flip off for hard edges.
        fadeStartFraction        = 0.5,   -- fadeEnabled only: a dot stays fully opaque until this fraction of ITS OWN lifetime has elapsed (0.5 = halfway, ~22.5s in at the shipped default), then fades linearly the rest of the way to exactly 0 at expiry. Clamped to [0, 1) at read time.

        -- REVEAL (server/tracking.lua's getScentVisionPoints callback) --
        -- see server/tracking.lua's own header for why colours are scoped
        -- to a small "handful" of nearby trails rather than the whole
        -- server, and why that is also what keeps a query cheap at a large
        -- population.
        queryRangeMeters         = 40.0, -- how far from the QUERYING K9's own live position a dot must be to be revealed at all.
        maxVisibleTrails         = 5,    -- "a handful" (the owner's own word) -- how many DISTINCT people's trails one K9 is ever shown at once, nearest-first. This is also the exact ceiling on genuinely distinguishable colours this feature promises -- see `palette` below and server/tracking.lua's header. Raising this past #palette below reuses colours (a loud one-time warning is printed) rather than silently doing nothing.
        queryMaxPointsPerTrail   = 12,   -- per shown trail, at most this many of that person's own dots are revealed, nearest-to-the-K9-first -- a second cap on top of maxPointsPerPerson so a single trail's own on-screen density can be tuned independently of the storage-side cap.
        queryCooldownMs          = 1000, -- server-enforced FLOOR between one caller's queries, independent of the client's own poll cadence below -- defense-in-depth against a modified client polling faster than intended.
        pollIntervalMs           = 1500, -- the CLIENT's own target poll cadence while the ability is toggled on.

        -- ==================================================================
        -- MODE -- owner-directed pass: "make the scent tracking a keybind
        -- and choose always active or [not]". READ THIS EVEN IF YOU DO NOT
        -- CODE -- it decides whether your handlers have to press a button to
        -- see this at all, and what that choice costs.
        --
        -- Three plain-English choices, typed exactly as shown (in quotes,
        -- lowercase):
        --
        --   'keybind' (RECOMMENDED, and the default) -- a handler presses
        --   the key below (Z by default, rebindable per-player in their own
        --   FiveM Settings) to see the coloured dots, and presses it again
        --   to stop. This is the original brief exactly as asked for, and
        --   costs nothing extra: nobody sees anything on their screen until
        --   they deliberately ask for it.
        --
        --   'always' -- every eligible handler (certified, controlling
        --   their own K9, same access check as the keybind uses) sees the
        --   dots on their screen all the time, automatically, from the
        --   moment they are eligible, with nothing to press. Nobody has to
        --   remember a key, but nobody can turn it off for themselves
        --   either -- it is a server-wide decision, not a per-player
        --   preference. THE COST IS PURELY VISUAL, NOT PERFORMANCE: the
        --   server was already doing the population-wide work of recording
        --   everyone's recent footsteps whenever this feature is on at all
        --   (see the CAPTURE section above) -- 'always' does not make the
        --   server do one bit more of that work than 'keybind' already
        --   does. The only difference is who is looking at the results and
        --   when. The real cost is screen clutter: a handler mid-firefight
        --   or mid-conversation gets coloured dots on their screen whether
        --   they wanted them right then or not.
        --
        --   'off' -- nobody sees this at all, ever, and the key does
        --   nothing if pressed. Different from turning the whole
        --   Config.Features.ScentVision switch off further up this file:
        --   THAT stops the server from recording anyone's footsteps in the
        --   first place, so turning it back on later starts from nothing
        --   and needs a few minutes to build up trails again. `mode = 'off'`
        --   keeps that recording running quietly in the background the
        --   whole time -- so if you switch to 'keybind' or 'always' later,
        --   there is already a trail waiting, with no warm-up wait.
        --
        -- WHAT "CHOOSE" MEANS HERE, IN PRACTICE: this is a config.lua
        -- setting, not (yet) a high-command-tablet dial like the numeric
        -- settings above it -- change the value, save the file, and restart
        -- this resource (`restart qbx_k9unit`) for it to take effect, the
        -- same as almost every other setting in this file. (The handful of
        -- settings that skip the restart and apply the instant you save
        -- them from the tablet are the ones server/runtimecontrol.lua's own
        -- registry explicitly lists -- this is deliberately not one of
        -- them THIS PASS, because that registry only understands a number
        -- with a min and a max today, not a choice of words like this one;
        -- see that file's own comment next to `Tracking.ScentVision.*` for
        -- the honest "not built yet, not silently dropped" note.) One thing
        -- that IS instant, with no restart at all: if a handler is already
        -- looking at dots (from 'always', or from having pressed the key)
        -- the moment Config.Features.ScentVision itself gets switched off
        -- from the tablet, their screen clears immediately -- turning THAT
        -- switch off always wins, live, over whatever this `mode` says.
        --
        -- A typo or an unrecognised word here (anything other than the
        -- three exact strings above) is never a crash and never silently
        -- becomes 'always' by accident -- it falls back to 'keybind' (the
        -- safest, most conservative choice) and prints one clear warning to
        -- the server console naming this exact setting, the same
        -- clamp-and-warn promise every other setting in this file makes.
        mode = 'keybind',

        -- KEYBIND (client/keybinds.lua). A DEFAULT only, per this
        -- resource's standing RegisterKeyMapping convention -- a player who
        -- rebinds this in Settings keeps their own choice across a config
        -- edit or a resource update.
        --
        -- 'Z' -- NOT 'B'. A first pass shipped 'B' here without checking
        -- that Config.Combat.BiteAndHold.toggleKeybind (further down this
        -- same file) ALSO defaults to 'B' -- a real, ship-blocking
        -- collision found by the coordinator while wiring the tablet's
        -- Commands page entry for this command, not caught by this file's
        -- own header claim of having checked every existing
        -- RegisterKeyMapping default: that check only ever looked at
        -- LITERAL keys typed directly into a RegisterKeyMapping(...) call
        -- (grep-visible), never at a config-driven default like this one or
        -- BiteAndHold's own -- a config value has to be resolved, not
        -- grepped, to know what key it actually is. VERIFIED THIS TIME by
        -- reading the RESOLVED VALUE (not just the call site) of every
        -- RegisterKeyMapping default across this whole resource: 'X' (vault,
        -- client/agility.lua), 'N' (pursuit sprint, client/pursuitsprint.lua),
        -- 'L' (camera, client/movement.lua), 'H' (camera feed,
        -- Config.CameraFeed.toggleKey above), 'K'/'J' (thermal/night vision,
        -- Config.Vision.Thermal/.Night.toggleKey above), 'G' (handler-down
        -- confirm, Config.Combat.HandlerDownDefense.confirmKey below), 'V'/
        -- 'C'/'U' (sit/bark/recall, literals in client/keybinds.lua), 'B'
        -- (BiteAndHold.toggleKeybind, below), 'T' (NonLethalTakedown.keybind,
        -- below), 'Y' (PropDragging.toggleKeybind, below). 'Z' is not among
        -- them. If this file's own set of RegisterKeyMapping defaults grows
        -- again, re-verify by resolving every config-driven default's real
        -- value, not by grepping for literal single-quoted keys alone.
        --
        -- IF THIS CHANGES AGAIN: html/tablet.js's Commands page entry for
        -- `/k9scentvision` hardcodes `defaultKeybind: 'Z'` to match -- update
        -- both together, or the tablet teaches players the wrong key, which
        -- is worse than not mentioning one at all.
        keybind = 'Z',

        -- One fixed, curated swatch per `maxVisibleTrails` slot -- NOT a
        -- hash into an arbitrarily large colour space. Colour assignment is
        -- scoped to the small, proximity-ranked visible set above, so a
        -- fixed one-swatch-per-slot palette this length makes a colour
        -- collision between two SIMULTANEOUSLY SHOWN trails structurally
        -- impossible, as long as this array is at least `maxVisibleTrails`
        -- long. Chosen for maximum hue/lightness separation at a glance,
        -- not a rigorous colour-vision-deficiency-optimised set -- flagged
        -- for a coder-ui/native-api-assistant pass if that guarantee is
        -- ever needed. Extra entries beyond `maxVisibleTrails` are simply
        -- never used; fewer entries than `maxVisibleTrails` triggers the
        -- reuse warning noted above.
        palette = {
            { r = 230, g = 25,  b = 75  }, -- red
            { r = 60,  g = 180, b = 75  }, -- green
            { r = 255, g = 225, b = 25  }, -- yellow
            { r = 0,   g = 130, b = 200 }, -- blue
            { r = 245, g = 130, b = 48  }, -- orange
        },
    },
}

-- Water crossing degrades/breaks a visible trail (§6.3, §11.5). Applied by
-- client/tracking.lua while rendering ANY active trail (scent, blood, or
-- gunpowder) -- not a separate trackable type of its own, which is why it
-- has no maxRange/searchCooldownMs of its own above.
Config.WaterTrackingDecay = {
    sampleIntervalMeters = 2.0,  -- how often the rendered path is sampled for water while drawing it. Use GetWaterHeightNoWaves (0x8EE6B53CE13A9794), NOT plain GetWaterHeight -- confirmed by two independent native-verification passes that the wave-motion jitter in plain GetWaterHeight can cause inconsistent water/no-water reads between adjacent samples on calm shorelines; NoWaves gives a frame-stable read appropriate for a fixed-step poll like this.
    breaksTrail          = true, -- true: water fully breaks the trail, handler must re-search on the far bank (§6.3's stated behavior); false: only fades marker opacity near/in water instead of a hard break -- a softer alternative flagged here as a one-line config choice, not a spec mandate either way
}

-- ======================================================================
-- SEARCH ZONES & CONTRABAND. Item names below must match real
-- ox_inventory item names on the target server -- PLACEHOLDER list, needs
-- a config-validator/economy review before this ships for real. Item
-- WEIGHT for tier computation is read live from ox_inventory's own item
-- registry at search time, never duplicated into this config, so there is
-- exactly one source of truth for item weight and it can never drift out
-- of sync with a server's real items.lua.
-- ======================================================================
Config.SearchContrabandItems = {
    'weed_bud', 'coke_brick', 'meth_bag', 'weapon_pistol', -- placeholder examples only
}

Config.SearchZones = {
    vehicleSearchDistance = 2.0,   -- ox_target zone radius for "Search Vehicle"
    personSearchDistance  = 2.0,   -- ox_target zone radius for "Search Person"
    sniffAnimDurationMs   = 4000,  -- how long the sniff interaction takes before the result is revealed
    -- CORRECTED: this is a per-TARGET cooldown, SHARED ACROSS EVERY
    -- SEARCHER. It has no K9/searcher dimension at all -- see
    -- server/search.lua's TargetSearchCooldown, which keys only on the
    -- resolved plate or citizenid. The old comment here claimed
    -- "per-(K9, target)", which is what made the contraband XP farm look
    -- bounded when it was not: two officers alternating never wait, and one
    -- officer toggling a stash they control was throttled only by this.
    -- The XP award is now separately gated by a per-searcher mint cooldown
    -- in server/search.lua. Contrast Config.Wellbeing.Mood.petCooldownMs,
    -- whose "per-(interactor, target)" claim IS accurate.
    searchCooldownMs      = 10000, -- prevents repeat-search spam against the same vehicle/person to fish for a different roll or just to harass
    alertBroadcastRadius  = 15.0,  -- max distance from the searched target's own live coordinates for a bystander to receive the ContrabandAlerts sound/reaction broadcast. Deliberately NOT a global TriggerClientEvent(-1, ...) like relayBark -- unlike a bark, this payload identifies a specific vehicle/person just flagged for contraband, so broadcasting it map-wide would leak that fact to an accomplice anywhere on the server. server/search.lua must iterate connected players and filter by this radius before sending. HARD CEILING: 200.0m, enforced in code (server/search.lua's own onResourceStart guard) -- a value above that is clamped back down to 200.0 rather than honored, specifically so this can never be raised high enough to functionally become a map-wide broadcast.
}

-- ======================================================================
-- DOOR INTERACTION (nudge-open / scratch-to-alert). See §11.6
-- for why "nudge-open" is conditioned on the target server having a
-- separate door-lock resource, and why it's scoped client-only (mirrors
-- the vehicle-entry-exit "no real capability granted" exception in §4.1).
-- ======================================================================
Config.DoorInteraction = {
    interactDistance      = 1.5,  -- max distance to a door entity to show either option
    nudgeRequiresUnlocked = true, -- hard requirement, not a toggle: nudge-open must never function as a lockpick bypass -- see §11.6
    scratchCooldownMs     = 3000, -- per-player cooldown on the scratch-to-alert sound cue, same rationale as Config.Features.BasicBarkSounds' server-side cooldown in server/main.lua
}

-- ======================================================================
-- VISION (thermal / night). Both are native-toggle keybinds, no
-- custom shader/asset -- see §11.6 for the exact natives confirmed/refined
-- against DEVELOPER_REFERENCE.md §7's original claim.
-- ======================================================================
-- client/vision.lua. Tuning for the partner camera feed above.
Config.CameraFeed = {
    toggleKey              = 'H',   -- rebindable in-game like any other key
    fov                    = 50.0,  -- field of view, degrees. Lower = more zoomed in.
    k9EyeHeightOffset      = 0.65,  -- metres above a dog-shaped partner's feet. Approximate, not read off the model — tune it for the breeds you actually use.
    handlerEyeHeightOffset = 1.6,   -- metres above a human-shaped partner's feet. Same caveat.
}

Config.Vision = {
    Thermal = { toggleKey = 'K' }, -- drives SetSeethrough(true/false) -- see §11.6
    Night   = { toggleKey = 'J' }, -- drives SetNightvision(true/false) -- see §11.6
}

-- ======================================================================
-- COMBAT & ADVANCED AGILITY (DEVELOPER_REFERENCE.md §12.2).
--
-- UPDATE (coder-security, this pass): DEVELOPER_REFERENCE.md §12.0 item 8 (the
-- client-relay/non-cooperating-target-client architecture question) is now
-- RESOLVED (Revision 4) — see that item's own "ship it, with binding
-- guardrails" verdict. `BiteAndHold` and `NonLethalTakedown` (including
-- their PLAYER-target paths, gated by `RequireWantedStatus` below) are
-- implemented this pass in `server/combat.lua` / `client/combat.lua`,
-- under item 8's five binding guardrails. `Config.Features.BiteAndHold`/
-- `NonLethalTakedown` shipped `false` above at that point — shipping the
-- code gated-off-by-default was not the same decision as flipping either
-- flag on a live server, which still wanted its own separate go/no-go
-- (balance review, anim preview for BiteAndHold). That review has SINCE
-- happened: server/combat.lua's own header records the red-team
-- trust-boundary pass both features went through, and `BiteAndHold`/
-- `NonLethalTakedown` now ship `true` above. This paragraph is kept only
-- for the history of why the implementation and the flag flip were
-- originally separate decisions.
--
-- STILL DELIBERATELY NOT ADDED — genuinely different, still-open blockers:
--   - `PropDragging` is OUT OF SCOPE for this pass (not requested, not
--     implemented) — its config entries stay absent rather than added as
--     dead placeholders. It shares item 8's Category B relay exposure for
--     its drag-speed-limit half (see item 8's own write-up) and ADDITIONALLY
--     needs DEVELOPER_REFERENCE.md §12.0 item 6's downed-check contract for a
--     player target, so it is not simply "the same pattern, one more
--     feature" — left for whoever picks it up next to design/implement
--     against item 8's already-resolved guardrails directly.
--   - `HandlerDownDefense` NO LONGER BLOCKED, AND NEITHER IS PropDragging.
--     Both of the "blocked" write-ups above and here are superseded and are
--     kept only so the reasoning that unblocked them is legible:
--       * PropDragging shipped -- see Config.Combat.PropDragging below,
--         plus client/combat.lua and server/combat.lua.
--       * HandlerDownDefense shipped -- see Config.Combat.HandlerDownDefense
--         below, plus server/defense.lua and client/defense.lua. Its stated
--         blocker (DEVELOPER_REFERENCE.md §12.0 item 7, "who is this K9's handler")
--         was resolved by the HandlerPartnership registry landing.
--         NOTE, because the spec was WRONG about this and a future editor
--         will otherwise re-derive it: §12.3 assumed HandlerDownDefense
--         could reuse an attacker identity from `relayDamageEvent`. That
--         event is deliberately PAYLOAD-LESS -- there is no attacker field
--         to reuse. server/defense.lua therefore carries its own, explicitly
--         low-trust hint channel, and no server-authoritative consequence
--         depends on that hint; the K9's confirmation is re-validated from
--         scratch by ValidateCombatRequest.
--     Both features shipped `false` at that point, per this resource's
--     convention that a newly-landed mechanic stays off until its own
--     go-live review. That review has SINCE happened for both:
--     server/defense.lua's own header documents HandlerDownDefense being
--     flipped to `true` by the config owner after its go-live review, and
--     server/combat.lua's red-team trust-boundary pass covers PropDragging
--     the same way it covers BiteAndHold/NonLethalTakedown above. Both
--     `Config.Combat.PropDragging` and `Config.Combat.HandlerDownDefense`
--     now ship `true` above.
-- Re-diff this block against DEVELOPER_REFERENCE.md §12.2 in full if either of the
-- above is picked up later, rather than assuming this copy stays in sync.
-- ======================================================================
Config.Combat = {
    -- Can a K9 bite, take down or drag someone who is SITTING IN A
    -- VEHICLE? Default false -- a dog physically biting a person through
    -- a car door is almost certainly not what you want, and nothing was
    -- stopping it before this setting existed.
    --
    -- This is a game-design call as much as a safety one, so it is a
    -- switch rather than a decision made for you. The case for turning it
    -- ON is dragging: pulling a downed driver out of a car is a plausible
    -- thing to want, and this one setting currently covers all three
    -- actions together. If you want dragging allowed but biting not, say
    -- so and it can be split per action.
    ExcludeVehicleSeatedTargets = true,

    -- Applies to BiteAndHold and NonLethalTakedown's player-target paths
    -- below (and would apply to PropDragging's, if/when that's built).
    -- DEVELOPER_REFERENCE.md §12.0 item 5 — RESOLVED, secure-by-default.
    RequireWantedStatus = true, -- a K9 may only target a PLAYER who is flagged wanted/suspect. Does NOT affect NPC targets (a "wanted" concept doesn't apply to an NPC this resource has no reason to protect from griefing).

    -- function(playerId: number) -> boolean, OPTIONAL, nil by default.
    -- Expected to be the NORMAL path for a real server, not the exceptional
    -- one — DEVELOPER_REFERENCE.md §12.0 item 5's own fragmentation note flags the
    -- default metadata guess below as LOWER CONFIDENCE than
    -- PropDragging's equivalent (`IsPlayerDownedOverride`, not yet added —
    -- see this file's PropDragging note above), because there is no single
    -- ecosystem-dominant convention for exposing a networked player's
    -- "wanted" state the way there is for a downed/laststand flag. Wire
    -- this directly to your dispatch resource's own export/state
    -- (cd_dispatch/ps-dispatch/qs-dispatch/in-house all differ). If this
    -- errors when called, server/combat.lua FAILS CLOSED (treats the
    -- target as NOT eligible) rather than falling back to the default
    -- metadata guess below — a broken override must never silently widen
    -- who can be targeted.
    WantedStatusCheckOverride = nil,
    -- Default best-effort check used ONLY when the override above is nil:
    -- reads `metadata.wanted` / `metadata.iswanted` off the target's own
    -- qbx_core PlayerData if present. See the confidence note above before
    -- relying on this in production — most real servers are expected to
    -- supply the override instead.

    -- DEVELOPER_REFERENCE.md §12.0 item 8 — DETECTION ONLY, NEVER ENFORCEMENT (see
    -- that item's guardrail 3: no server-authoritative consequence may ever
    -- be conditioned on one of these signals firing). Real, implemented
    -- sampling in `server/combat.lua`, not a sketch — see that file's own
    -- "NON-COMPLIANCE DETECTION" section for the full design writeup this
    -- table's fields map onto.
    NonComplianceDetection = {
        -- DEFAULT CHANGED true -> false, and the reason recorded here used
        -- to be wrong in a way worth correcting rather than deleting.
        --
        -- It used to say this flag is independent of BiteAndHold/
        -- NonLethalTakedown/PropDragging/HandlerDownDefense "which all
        -- default false", so leaving it on would spin a 500ms thread
        -- sweeping a table that stays empty on a default install. Those four
        -- actually default TRUE (see Config.Features above), so on a default
        -- install that table is NOT empty and the thread would have had real
        -- work to do. The stated reasoning was backwards.
        --
        -- The setting itself is still correctly false, for a different and
        -- better reason: this is DETECTION ONLY and never enforcement (see
        -- guardrail 3 above), its thresholds below are openly marked
        -- UNTUNED, and its output is a log line nobody has asked for. An
        -- untuned detector running on every install produces noise a server
        -- owner then has to learn to ignore, which is worse than no detector
        -- at all. Turn it on when you actually intend to read what it
        -- reports, and expect to tune the numbers below against your own
        -- server before trusting them.
        enabled                = false,
        positionSampleWindowMs = 500,   -- how often the shared sampling thread re-reads every active hold/ragdoll's target position
        biteHoldIdleCeiling    = 0.3,   -- m/s -- a compliant BiteAndHold target is near-stationary (may turn in place); observed speed above (idleCeiling + biteHoldSpeedTolerance) is a candidate violation. UNTUNED placeholder, per item 8's own numbers.
        biteHoldSpeedTolerance = 0.5,   -- m/s -- item 8's own tightened recommendation for BiteAndHold specifically. Item 8's generic speedTolerance=1.0 baseline was flagged as too loose stacked on a 0.3 m/s idle ceiling, and has been deleted from this table entirely -- an audit confirmed it had no reader anywhere in the resource, under any feature flag; every effect type carries its own dedicated threshold instead. UNTUNED.
        biteHoldViolationSamples = 2,   -- consecutive over-threshold samples required before flagging — never a single noisy sample, per item 8's "never auto-punish/flag on one sample" instinct (mirrors server/tracking.lua's own FORGED TRAIL DECISION reasoning).
        takedownNetDisplacementMeters = 3.0, -- meters -- NonLethalTakedown uses NET DISPLACEMENT from the ragdoll-start position over the whole window as its primary signal instead of a continuous speed check (a genuine ragdoll produces noisy per-tick velocity from falling/sliding that a speed check would false-positive on) — see server/combat.lua's own comment for the disclosed simplification versus item 8's fuller "sustained consistent heading, not random tumbling drift" framing. UNTUNED.
        action                 = 'log', -- 'log' | 'notify_staff' -- deliberately NEVER 'auto_kick'/'auto_ban': a false positive from lag/desync must not itself become a punitive action without human review.
        -- function(playerId: number, effectType: string, evidence: table) -> nil, OPTIONAL, nil by default.
        -- A server that wants automated response beyond log/notify_staff
        -- builds it here, on top of real evidence — this resource never
        -- takes a punitive action on its own initiative. Any error raised
        -- by this callback is caught and logged; it never interrupts the
        -- sampling thread for other active holds.
        OnViolationOverride    = nil,
        -- PropDragging's own compliance slack, in METERS. Distinct from the
        -- speed-based thresholds above BY DESIGN: a drag's compliance
        -- signal compares the target's live position against the DRAGGING
        -- K9's own live position, not against an absolute speed ceiling,
        -- because DEVELOPER_REFERENCE.md §12.0 item 8's corollary is that a hostile
        -- target can simply self-detach (DetachEntity is very likely not
        -- ownership-gated). A target that has broken free reads as a
        -- growing gap, which an absolute speed ceiling would miss entirely.
        -- Log-only like every other field here — the ACTUAL enforcement for
        -- a runaway drag is Config.Combat.PropDragging.maxDragDistance
        -- below, which is checked unconditionally and is never gated behind
        -- `enabled`.
        dragComplianceSlackMeters = 4.0,
    },

    -- DEVELOPER_REFERENCE.md §12.5.4. MIXED Category A/B per §12.0 item 8, and the
    -- only Phase 3 mechanic that is: the ATTACH is Category A (server-side
    -- authoritative, robust against a hostile target client) while the
    -- SPEED LIMIT is Category B (SetPedMoveRateOverride is local-only, so a
    -- modified target client can ignore it). client/combat.lua re-asserts
    -- the attach EVERY TICK rather than once, specifically because a target
    -- can self-detach — see that file's own guardrail comments.
    -- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
    -- balance pass, same status as every other Phase 3 tuning number here.
    PropDragging = {
        range              = 2.5,    -- meters, self-initiated trigger range (matches BiteAndHold's)
        -- HOW LONG THIS K9 MUST WAIT BEFORE STARTING ANOTHER DRAG, in
        -- milliseconds (1000 = one second). Counts from the moment a drag
        -- STARTS. Deliberately shorter than Bite & Hold's 20 seconds or a
        -- Takedown's 25: moving several downed people at one scene is the
        -- normal, intended use of this, and a long wait between bodies
        -- would punish exactly the thing the feature is for. What this
        -- number stops is a K9 firing the same request over and over.
        -- LOWER = the dog can start drags more often. HIGHER = less often.
        cooldownMs         = 8000,
        -- HOW LONG THE SAME PERSON IS LEFT ALONE, in milliseconds, counted
        -- from the moment a drag on them starts. This is the one that
        -- matters for fairness rather than spam.
        --
        -- A dragged person can let go themselves at any time (their own
        -- Drag / Release key). Without this number that escape would be
        -- worthless: the dog could simply grab them again the same second,
        -- forever, and a downed player would have no way out of the loop
        -- short of disconnecting. Set to the same 20 seconds as
        -- maxDragDurationMs below, so a drag that is allowed to run its
        -- full length can be followed straight away by another one (the
        -- legitimate "keep moving them further" case), while a drag the
        -- person escaped from two seconds in buys them the remaining
        -- eighteen.
        --
        -- LOWER = the same person can be re-grabbed sooner. HIGHER = they
        -- get longer between drags. Setting this to 0 or a negative number
        -- is refused and this default is used instead, with a warning.
        targetCooldownMs   = 20000,
        maxDragDistance    = 30.0,   -- meters from the drag's start point before the server force-ends it. THIS is the real "no unbounded trap" enforcement — checked unconditionally in the maintenance loop, never gated behind NonComplianceDetection.enabled.
        maxDragDurationMs  = 20000,  -- hard timeout if never manually released, same role as BiteAndHold's maxDurationMs
        dragSpeedMultiplier = 0.4,   -- Category B: applied to the TARGET's move rate while dragged. A modified client may ignore this; that is disclosed, not solved.
        -- function(targetServerId: number) -> boolean|nil, OPTIONAL.
        -- DEVELOPER_REFERENCE.md §12.0 item 6 made this a REQUIRED active config
        -- surface rather than a commented-out placeholder, because the
        -- native-only fallback is genuinely unreliable for players:
        -- IsPedDeadOrDying/IsPedRagdoll measure raw physics state, not a
        -- server's scripted laststand, so they both false-positive (a
        -- ragdolling but conscious player) and false-negative (a player in
        -- a scripted laststand that keeps the ped "alive"). Point this at
        -- your own ambulance/laststand resource. server/combat.lua FAILS
        -- CLOSED if this errors — treats the target as NOT downed — and
        -- only falls back to a best-effort metadata.isdead/.inlaststand
        -- guess when this is nil, exactly like WantedStatusCheckOverride
        -- above.
        IsPlayerDownedOverride = nil,
        -- Default keyboard key for the "Drag / Release" TOGGLE keybind
        -- (client/keybinds.lua registers `k9dragtoggle` + this as its
        -- RegisterKeyMapping default). Always rebindable client-side, same
        -- disclosure as HandlerDownDefense.confirmKey below -- and the same
        -- REAL CONSTRAINT: RegisterKeyMapping only sets a DEFAULT. Once a
        -- player has rebound this in Settings > Key Bindings > FiveM,
        -- changing this value in a later config update does NOT move their
        -- existing binding -- it only changes what a BRAND NEW player (or
        -- one who never touched this specific binding) starts with.
        toggleKeybind = 'Y',
    },

    -- DEVELOPER_REFERENCE.md §12.5.3, implemented in server/defense.lua +
    -- client/defense.lua. Per §12.0 item 2 this is a UI/auto-targeting
    -- CONVENIENCE, never an AI takeover — the K9 never acts on its own; a
    -- prompt is surfaced faster and the player still confirms.
    --
    -- Reuses Config.Combat.PropDragging.IsPlayerDownedOverride rather than
    -- adding its own: "is this player down per the server's own scripted
    -- laststand" is the same question for a drag target and a handler, and
    -- the same native-unreliability caveat applies (IsPedDeadOrDying /
    -- IsPedRagdoll read raw physics, not laststand state).
    --
    -- ALL NUMERIC VALUES BELOW ARE UNREVIEWED PLACEHOLDERS pending a
    -- balance pass, same status as every other Phase 3 tuning number here.
    HandlerDownDefense = {
        -- RAISED 100 -> 140. 100 is GTA's own player-ped "already dying"
        -- boundary -- this resource documents it as exactly that where
        -- NonLethalTakedown uses it as a health FLOOR, which is correct there.
        -- As a TRIGGER for "alert my partner K9, my handler is in trouble" it
        -- meant the alert only fired once the handler was already at the death
        -- line, leaving no lead time for the K9 to actually respond -- the
        -- number was right for its original use and wrong for this one.
        handlerHealthThreshold   = 140,   -- fallback-only signal; the override above is the real check
        triggerRadius            = 15.0,  -- how close the partner K9 must be to be prompted
        hostileLookbackSeconds   = 10,    -- how far back an attacker hint stays relevant
        pollIntervalMs           = 1000,
        retriggerCooldownMs      = 30000, -- anti-spam; stamped at send, not at retry (see server/defense.lua)
        promptTtlMs              = 10000, -- client-local clock, see that file's CLOCK-DOMAIN note
        attackerReportCooldownMs = 500,
        confirmKey               = 'G',   -- always rebindable client-side
    },

    BiteAndHold = {
        range         = 2.5,    -- meters, self-initiated trigger range
        maxDurationMs = 15000,  -- hard timeout if never manually released — THIS IS the "no unbounded trap" guarantee for a non-consensual mechanic, DEVELOPER_REFERENCE.md §12.0 item 4. Never remove without an equally-hard replacement cap.
        cooldownMs    = 20000,  -- per-K9 cooldown between attempts
        -- Per-target cooldown, mirroring NonLethalTakedown.targetCooldownMs
        -- below. Without it the per-K9 cooldown is the only bound, and the
        -- `already_held` check does not help -- that only blocks a second
        -- CONCURRENT hold by a DIFFERENT K9, not the same K9 re-taking the
        -- same target once its own cooldown clears. A compliant or AFK
        -- target could therefore be bite-held every 20s indefinitely, each
        -- hold over MIN_BITE_HOLD_XP_DURATION_MS paying biteHoldSuccess --
        -- roughly 60 XP/min against one stationary target with no travel
        -- and no variety. Set slightly above NonLethalTakedown's 30000 on
        -- purpose: a bite hold can pay out every 3s of a 15s window,
        -- whereas a takedown is a single discrete event.
        --
        -- What this bounds, precisely: 35000 exceeds the 20000 per-K9
        -- cooldown, so against ONE target the per-target gate binds and the
        -- ceiling is about 2057 XP/hr. With two or more targets available
        -- the per-K9 cooldown binds instead and the ceiling rises to about
        -- 3600 XP/hr. That second number is the honest one for a populated
        -- server -- the per-target gate closes the degenerate
        -- single-stationary-target farm, it does not cap the mechanic
        -- overall, and the per-K9 cooldown was always the intended throttle
        -- for legitimate repeated use.
        targetCooldownMs = 35000,
        -- Default keyboard key for the "Bite & Hold / Release" TOGGLE
        -- keybind (client/keybinds.lua registers `k9bitehold` + this as its
        -- RegisterKeyMapping default). Always rebindable client-side -- see
        -- PropDragging.toggleKeybind above for the full disclosure of the
        -- REAL CONSTRAINT: RegisterKeyMapping only sets a DEFAULT and
        -- cannot move a player's own already-rebound key.
        toggleKeybind = 'B',
    },
    NonLethalTakedown = {
        range               = 3.0,
        minTargetSpeed      = 4.0,   -- m/s, SERVER-COMPUTED from a short position-sample window at request time (see server/combat.lua's own note on why this is a bounded two-sample measurement, not a continuously-running per-ped tracker) — never a client-claimed "I am sprinting" flag. Applies identically whether the target is an NPC or a player.
        speedSampleWindowMs = 250,   -- how long the server waits between its two position samples to compute the target's speed for the check above — UNTUNED, and itself re-validates everything (existence, proximity, already-held, eligibility) again after the wait, same TOCTOU discipline as this resource's other yielding server calls.
        ragdollDurationMs   = 4000,  -- hard cap on BOTH the forced-ragdoll hold and the SetEntityCanBeDamaged(false) bracket — THIS IS the "no unbounded trap" guarantee for this mechanic, DEVELOPER_REFERENCE.md §12.0 item 4 (named there explicitly as "the ragdoll/damage-suppression window in NonLethalTakedown"). UNTUNED.
        ragdollFallTimeMs   = 1000,  -- how long the suspect is driven into the fall animation, in ms. Source-confirmed as the duration parameter of the underlying game call. Keep it below ragdollDurationMs above -- the fall should finish inside the damage-immunity window, not outlive it. UNTUNED: dimensionally sane, but how it FEELS needs a live test.
        ragdollFallTimeP2   = 1500,  -- a second timing value the same game call takes. Honest warning: the game's own documentation says testers could not work out what it does ("didn't seem to affect anything"), so changing this may do literally nothing. Exposed anyway because it costs nothing and a live test on your build might disagree. If tuning it changes nothing, that is the expected result, not a bug.
        cooldownMs          = 25000, -- per-K9 cooldown
        targetCooldownMs    = 30000, -- per-target cooldown -- stops repeat takedowns of the same already-downed target by multiple K9s in quick succession
        healthFloor         = 100,   -- backstop only, NOT the primary non-lethal mechanism -- primary mechanism is the SetEntityCanBeDamaged bracket above
        -- Default keyboard key for the (non-toggle, one-shot) "Non-Lethal
        -- Takedown" keybind (client/keybinds.lua registers `k9takedown` +
        -- this as its RegisterKeyMapping default). Always rebindable
        -- client-side -- see PropDragging.toggleKeybind above for the full
        -- disclosure of the REAL CONSTRAINT: RegisterKeyMapping only sets a
        -- DEFAULT and cannot move a player's own already-rebound key.
        keybind             = 'T',
    },

    AgilityAdvanced = {
        -- DECIDED (DEVELOPER_REFERENCE.md §12.0 item 3, Revision 2, unaffected by
        -- the Revision 3 PvP reversal): multi-height capsule-sweep raycast
        -- is the Phase 3 default. 'taggedProp' remains a documented,
        -- theoretical per-server override shape but has NO implementation
        -- in this codebase — client/movement.lua asserts loudly at
        -- resource start if this is ever set to anything other than
        -- 'raycast', rather than silently no-op'ing.
        detectionMethod = 'raycast',
        maxVaultHeight  = 1.2,   -- meters -- DEVELOPER_REFERENCE.md §12.2 sketch value, UNTUNED (see client/movement.lua's own tuning-constants note: DEVELOPER_REFERENCE.md §12.5.5 lists exact height bands/capsule radius/forward distance as in-engine tuning work, not a design fork)
        vaultCooldownMs = 2000,  -- ms, UNTUNED placeholder, same status as above
    },
}

-- ======================================================================
-- HANDLER/K9 PARTNERSHIP REGISTRY (Config.Features.HandlerPartnership,
-- server/partnership.lua + client/partnership.lua). DEVELOPER_REFERENCE.md §12.0
-- item 7 (Revision 5, coder-architect) / §12.3's file-plan entry.
--
-- OWN TOP-LEVEL BLOCK, DELIBERATELY NOT NESTED UNDER Config.Combat: this
-- mechanic has its OWN file, its OWN feature flag (independent of
-- BiteAndHold/HandlerDownDefense per the resolved design's explicit
-- "one-flag-per-mechanic" reasoning), and its own owner (server/
-- partnership.lua, not server/combat.lua) — nesting its tuning knobs inside
-- Config.Combat (a different file's config namespace) would blur that
-- ownership split for no benefit. Mirrors this file's own established
-- convention of one dedicated top-level table per Phase 2/3 feature
-- (Config.Tracking, Config.SearchZones, Config.DoorInteraction, Config.Vision,
-- Config.Combat above) rather than a single everything-table.
--
-- This registry started as a FOUNDATION ONLY, with no combat consequence
-- wired to it. That is no longer true, and this note is kept only so the
-- progression is legible: both mechanics DEVELOPER_REFERENCE.md 12.0 item 7 named as
-- blocked on this registry existing are now built and consuming it --
-- HandlerDownDefense's trigger (server/defense.lua) and the Recall actor
-- (server/recall.lua, Config.Recall below). Both call
-- `GetActivePartnerCitizenId`/`IsActivePartnerOf` directly rather than
-- re-deriving their own partner lookup, per this registry's accessor
-- contract (see server/partnership.lua's header). A third consumer,
-- server/tenure.lua, reads the same registry for the tenure bonus.
-- ======================================================================
Config.Partnership = {
    -- DEVELOPER_REFERENCE.md §12.0 item 7 point 1 explicitly leaves "reuse
    -- Config.CertifyProximityMeters or a dedicated
    -- Config.Combat.PartnerProximityMeters" as an implementer's call, not a
    -- design fork. A DEDICATED constant is used here (not a direct reuse of
    -- Config.CertifyProximityMeters, and not nested under Config.Combat --
    -- see this block's own header above) so this mechanic's own proximity
    -- rule can be tuned independently of certification's without an
    -- unrelated cross-feature edit. Same 5.0m default as
    -- Config.CertifyProximityMeters purely because it's a reasonable
    -- starting point for the same class of "stand near each other and
    -- confirm" interaction, not because the two are meant to stay coupled.
    ProximityMeters   = 5.0,

    -- Mirrors server/main.lua's LEASH_REQUEST_TTL_MS / LEASH_REQUEST_COOLDOWN_MS
    -- exactly (same "a request nobody answers shouldn't linger indefinitely
    -- available for a stale accept" / "stop UI-harassment via repeat
    -- prompts" reasoning as the leash consent handshake this mechanic
    -- deliberately mirrors — DEVELOPER_REFERENCE.md §12.0 item 7 point 1).
    RequestTTLMs      = 30000,
    RequestCooldownMs = 1000,

    -- server/tenure.lua (Config.Features.PartnershipTenureBonus). Nested
    -- here rather than given its own top-level block because it tunes THIS
    -- mechanic's payoff, not a subsystem of its own.
    TenureBonus = {
        -- server/tenure.lua's poll cadence, independent of
        -- Config.Wellbeing.tickIntervalMs (an unrelated subsystem).
        -- Milestones are hours-to-days away, so a coarse interval costs
        -- nothing in perceived responsiveness and keeps the one indexed
        -- SELECT this adds per online, actively-partnered K9 effectively
        -- free.
        checkIntervalMs = 300000, -- 5 minutes

        -- MUST stay sorted ascending by afterSeconds -- server/tenure.lua's
        -- tier walk breaks on the first unmet threshold, mirroring
        -- Config.ContrabandAlertTiers' identical documented ordering
        -- requirement. Each actionKey must have a matching entry in
        -- Config.XP.awards above, or the award silently resolves to nothing.
        --
        -- `handlerActionKey` -- OPTIONAL. WIRED (dead-config-field audit
        -- correction: this comment used to claim it was "NOT YET READ by
        -- server/tenure.lua" and "inert data with no consumer" -- false,
        -- and had been false since server/tenure.lua's own
        -- CheckTenureMilestonesForK9 was written; re-verified by reading
        -- that function directly before writing this note, not assumed).
        -- server/tenure.lua's `for tier = alreadyGranted + 1, targetTier do`
        -- loop already calls, immediately after its
        -- `AwardXP(k9Citizenid, milestone.actionKey)` line:
        --     if type(AwardHandlerXP) == 'function' and milestone and type(milestone.handlerActionKey) == 'string' then
        --         AwardHandlerXP(row.handler_citizenid, milestone.handlerActionKey)
        --     end
        -- paying the matching entry in Config.HandlerXP.awards above to
        -- `row.handler_citizenid` the SAME tick `actionKey` is paid to
        -- `k9Citizenid`. Same soft-dependency guard shape that call site
        -- already uses for AwardXP itself. Inherits that loop's existing
        -- one-time-per-row CAS guard and same-pair-reform seeding for free
        -- -- no separate anti-farm state needed for this half. Leaving a
        -- milestone entry's own `handlerActionKey` unset (or blank) simply
        -- pays no handler XP for that tier -- it does not error, and it is
        -- the only way left to opt a custom milestone OUT of paying handler
        -- XP at all.
        milestones = {
            { afterSeconds = 86400,   actionKey = 'partnershipTenure1Day',  handlerActionKey = 'handlerPartnershipTenure1Day'  },
            { afterSeconds = 604800,  actionKey = 'partnershipTenure7Day',  handlerActionKey = 'handlerPartnershipTenure7Day'  },
            { afterSeconds = 2592000, actionKey = 'partnershipTenure30Day', handlerActionKey = 'handlerPartnershipTenure30Day' },
        },
    },
}

-- ======================================================================
-- RECALL (Config.Features.Recall) -- server/recall.lua, client/recall.lua.
-- DEVELOPER_REFERENCE.md 12.5.1's "Recall actor": the handler's escape hatch for
-- ending whatever active effect their partnered K9 is holding.
--
-- READ THIS BEFORE TUNING: Recall is this resource's PRIMARY TERMINATION
-- PATH, and the cooldown below is the only throttle on it. It exists to
-- stop request spam, never to delay a legitimate first recall -- keep it
-- small. Do NOT add an access check, a proximity requirement, or a
-- feature-flag dependency on the combat mechanics to this path: a handler
-- whose certification is revoked mid-bite must still be able to call their
-- dog off, and every gate added here is a step toward the unbounded trap
-- this resource forbids outright.
-- ======================================================================
Config.Recall = {
    -- Per-CALLER (the handler issuing the recall) rate limit.
    RequestCooldownMs = 2000,
}

-- ======================================================================
-- CONTRABAND SCREEN FX (Config.Features.ContrabandScreenFX) --
-- client/screenfx.lua. A brief timecycle effect on the SEARCHING K9 player's
-- own screen when their search turns up contraband -- sensory feedback for the
-- dog, not a penalty applied to the suspect.
--
-- An earlier version of THIS COMMENT said "the SEARCHED player's own screen",
-- which never matched the code: server/search.lua fires this at `source`, the
-- searcher. The code is the intended behaviour and the comment was wrong.
-- Worth stating rather than silently editing, because a future maintainer
-- reading only the old comment would have "fixed" the code to match it and
-- turned a cosmetic self-effect into something applied to another player.
-- ======================================================================
Config.ContrabandScreenFX = {
    -- Which Config.ContrabandAlertTiers tier(s) trigger the effect. Only
    -- the most severe by default -- firing on every tier would make this
    -- constant rather than notable.
    triggerTiers = { 'aggressive_bark' },

    -- VERIFIED. The candidate that shipped here first, 'drug_wobbly_shroom',
    -- DOES NOT EXIST -- a native audit checked every `drug_`-prefixed entry in
    -- a real game-data extraction of 2806+ timecycle modifiers and found only
    -- 'drug_wobbly' (56 modifications, "Drug" category, base game). The wrong
    -- name would have been a silent no-op forever: the feature would have
    -- shipped, been enabled, and simply never shown anything, with nothing in
    -- the logs to say why.
    modifierName = 'drug_wobbly',

    -- Deliberately well below DEVELOPER_REFERENCE.md 13.2's 8000ms sketch: this is
    -- meant to be feedback, not a screen-blocking penalty, and the
    -- modifier family is a disorienting one. client/screenfx.lua clamps its
    -- own effective ceiling to 4000ms regardless of what is set here.
    durationMs = 3000,
}

-- ======================================================================
-- ADMIN AUDIT SURFACE (Config.Features.AdminAuditCommands) --
-- server/admin.lua. Read-only SELECTs over the three tables this resource
-- writes. No mutation path exists in that file at all.
-- ======================================================================
Config.AdminAudit = {
    -- WHO CAN RUN THESE: police job rank, not an ACE permission. A caller
    -- must hold a job listed in Config.Departments below, and either be a
    -- boss of that job (job.isboss) or sit at or above that department's
    -- own `auditGrade`. There is no ACE grant to configure -- the old
    -- AcePermission key was removed on 2026-08-25 when server/admin.lua
    -- switched to job rank. SET auditGrade DELIBERATELY: these commands
    -- expose who searched whom and when, so it is a privacy boundary as
    -- well as an admin one.

    -- Whether a `source == 0` caller bypasses the rank check. DEFAULTS OFF,
    -- and think before turning it on: in FiveM `source == 0` is not only the
    -- server console. It is also an RCON client (authenticated by
    -- rcon_password alone) and ANY other resource on this server calling
    -- ExecuteCommand -- these commands are registered unrestricted, so a
    -- compromised or buggy co-located resource could otherwise read the whole
    -- audit trail with no rank at all. Turning this on accepts all three.
    -- A genuine console operator can instead be given a job grade at or
    -- above auditGrade, or simply query the database directly.
    TrustConsole = false,

    -- Shared across all three commands, keyed by caller.
    CommandCooldownMs = 3000,

    -- Per-command result caps. server/admin.lua additionally clamps every
    -- one of these into [1, 100] in code regardless of what is set here, so
    -- a careless edit cannot turn an audit command into a table dump.
    MaxResults = {
        Certifications = 25,
        Partnerships   = 25,
        SearchLog      = 25,
        -- GAP 2 closure (owner-directed "full control ... accountability"
        -- pass): backs the new qbx_k9unit:server:tabletAuditCatalog
        -- callback, which reads the eight previously write-only catalog-edit
        -- audit tables (cert tiers, permission keys, XP tiers, shop items,
        -- shop locations, per-K9 overrides, runtime overrides, tablet
        -- themes) -- server/admin.lua additionally clamps this into
        -- [1, 100] in code regardless of what is set here, same as every
        -- other key in this table.
        CatalogAudit   = 25,
    },
}

-- ======================================================================
-- PHASE 5 (R&D) — DEPLOYABLE KENNEL (Config.Features.DeployableKennel).
-- This shipped `false` by default when this section was written, pending
-- its own go-live review; that review has since happened and the flag now
-- ships `true` above.
-- DEVELOPER_REFERENCE.md#phase-5-research §5: "handler places a world...
-- kennel object... server-authoritative validation (proximity,
-- certification, one-per-handler limit), with cleanup on resource stop/
-- handler disconnect." See client/kennel.lua and server/kennel.lua for the
-- full implementation and their own file-header contracts.
--
-- PROP MODEL CONFIDENCE — read before changing `propModel` below:
-- `DEVELOPER_REFERENCE.md#phase-5-research` §5 found exactly ONE lead for a real
-- vanilla GTA doghouse/kennel prop name (`prop_doghouse_01`, sourced from
-- a DIFFERENT, unrelated FiveM resource's config default —
-- `fruitmob/murderface-pets`), and explicitly could NOT cross-verify it
-- against a second independent source this session (gtax.dev/gtahash.com/
-- a GTA Wiki "Doghouse" page were all blocked by this environment's
-- egress proxy). Per this project's established two-independent-source
-- confidence convention (see client/hud.lua's own stamina-native
-- confidence note for the same discipline applied to a native, applied
-- here to an asset name instead): PLAUSIBLE, NOT VERIFIED. Confirm it
-- actually streams/loads in-engine before treating it as settled — do not
-- silently upgrade this comment's confidence just because the feature
-- shipped without incident in one test session.
-- ======================================================================
Config.DeployableKennel = {
    -- Try this first. Single-source, unconfirmed lead — see the note
    -- above. client/kennel.lua's LoadModelWithTimeout() falls back to
    -- `fallbackPropModel` below if this model hash never loads within
    -- REQUEST_MODEL_TIMEOUT_MS, rather than silently placing nothing or
    -- erroring the whole feature out.
    -- REFUTED AND REPLACED 2026-08-25. `prop_doghouse_01` was carried on a
    -- single unverified source and does NOT appear in a 5,171-entry live
    -- object database that has an in-engine rendered screenshot per entry --
    -- its screenshot URL 404s. The two places the old name did appear both
    -- trace to author assumptions, and the "second" source turned out to be
    -- the same author reusing his own earlier config value, so it was never
    -- independent corroboration at all.
    -- `prop_dog_cage_01` (hash 379820688) IS in that database with a real
    -- rendered screenshot. Not exhaustive proof the old name is fake, but it
    -- is checkable evidence that affirmatively did not contain it while
    -- containing a real themed substitute.
    propModel = 'prop_dog_cage_01',

    -- Deliberately NOT a second guess at a "kennel-shaped" model name — a
    -- second unverified guess would carry the exact same single-source
    -- risk this fallback exists to avoid. Reuses `prop_tennis_ball`, the
    -- ONE prop name this same research pass (§4, FetchMechanic) rated
    -- highest-confidence "confirmed real and available" of any prop
    -- mentioned anywhere in that document — it traces to a real, working,
    -- source-read community script's shipped config default, not just a
    -- bare name reference. It is NOT thematically a kennel; it exists
    -- purely as a safe, visible, definitely-real placeholder so a bad
    -- `propModel` lead degrades to "an oddly-shaped but real object
    -- appears" rather than a silent failure or a broken/invisible entity.
    -- Swap for a real doghouse/kennel asset (custom-modeled or a
    -- confirmed vanilla prop) once one is verified in-engine.
    fallbackPropModel = 'prop_tennis_ball',

    -- Meters in front of the handler's own live server-side position
    -- (server/kennel.lua computes this from GetEntityForwardVector, never
    -- a client-claimed coordinate — see that file's header) where the
    -- kennel spawns before PlaceObjectOnGroundProperly snaps it to the
    -- ground. UNTUNED placeholder, same status as DEVELOPER_REFERENCE.md's own
    -- vault-tuning constants (client/movement.lua) — a reasonable-looking
    -- default, not a playtested value.
    placementForwardOffsetMeters = 2.0,

    -- ox_target interaction range for the "Pick Up Kennel" option
    -- (client/kennel.lua). Reuses the same order of magnitude as
    -- Config.VehicleInteractMeters's role for vehicle entry/exit rather
    -- than inventing an unrelated scale.
    interactDistanceMeters = 2.5,

    -- Per-source rate limit on *requesting* a new placement (server/
    -- kennel.lua's DeployCooldown) — spam defense only, distinct from the
    -- one-active-kennel-per-handler limit below (a handler who already has
    -- an active kennel is refused regardless of this cooldown; this only
    -- throttles how fast repeated requests can even reach that check).
    deployCooldownMs = 5000,

    -- How long server/kennel.lua holds a "waiting for the client to
    -- confirm it actually created the object" slot open before it expires
    -- and frees up for a new attempt — mirrors LEASH_REQUEST_TTL_MS's exact
    -- reasoning in server/main.lua (a request nobody ever answers must not
    -- linger indefinitely).
    pendingPlacementTtlMs = 15000,

    -- CARRY VISUAL (K9-can-ride-along pass -- "make the pickup feel real,"
    -- later corrected by the owner to "the SAME kennel, occupant and all,
    -- must move with the handler" -- see server/kennel.lua's own header
    -- CRITICAL SAFETY section for the full redesign this forced). Purely
    -- cosmetic bone/offset/rotation client/kennel.lua uses to
    -- AttachEntityToEntity the EXISTING, real, already-deployed kennel
    -- object onto a carrying handler's own ped -- NOT a freshly created
    -- prop (client/propattachment.lua's AttachPropToOwnPed is deliberately
    -- NOT used for this -- see client/kennel.lua's own header for why).
    -- UNTUNED placeholder, same disclosed-confidence status as
    -- placementForwardOffsetMeters above — boneIndex 0 (the root/pelvis
    -- bone) is deliberately used instead of a hand-specific bone: it is
    -- guaranteed valid on every ped skeleton (this resource's own
    -- client/combat.lua PropDragging attach already uses bone 0 for the
    -- same reason), whereas a specific hand-bone index could not be
    -- confirmed against a second independent source this session (the same
    -- egress-proxy blocker propModel's own confidence note above already
    -- discloses) and an invalid bone index is a real visual-placement risk,
    -- not just a cosmetic nitpick. The offsets below place the carried prop
    -- roughly in front of the handler's chest instead.
    carryBoneIndex = 0,
    carryOffsetX = 0.0,
    carryOffsetY = 0.3,
    carryOffsetZ = 0.35,
    carryRotX = 0.0,
    carryRotY = 0.0,
    carryRotZ = 0.0,

    -- REST VISUAL (K9-can-ride-along pass). Purely cosmetic offset
    -- client/kennel.lua uses to AttachEntityToEntity an occupant's OWN ped
    -- (a real, currently-connected player -- see server/kennel.lua's own
    -- header for why this is never a spawned ped) onto the kennel object
    -- itself. Defaults to the prop's own origin (0,0,0) rather than a
    -- guessed interior offset -- this feature's own propModel confidence
    -- note above already discloses that `prop_dog_cage_01`'s exact
    -- in-engine dimensions were never independently confirmed this
    -- session, so a guessed interior offset carries the identical
    -- unverified-asset risk the model name itself already carries; the
    -- origin is the one point guaranteed not to place the occupant
    -- floating outside the model's own bounds regardless of its real
    -- size.
    restOffsetX = 0.0,
    restOffsetY = 0.0,
    restOffsetZ = 0.0,
}
-- ONE-KENNEL-PER-HANDLER LIMIT (not a config knob — see server/kennel.lua's
-- header for the full "your call, documented" reasoning): the server-side
-- registry is a single-slot `Kennels[citizenid]`, not an array, so this is
-- a hardcoded invariant, not something a `maxActivePerHandler` field here
-- could raise without a real code change to the registry shape itself.
-- Deliberately NOT modeled as a per-area/spatial limit — see that file's
-- header for why.

-- ======================================================================
-- PHASE 5 (R&D) — ADVANCED BARK RADIAL (Config.Features.AdvancedBarkRadial —
-- layered on top of Config.Features.BasicBarkSounds per this resource's
-- existing Phase-5-on-Phase-1 convention, see client/radial.lua's Bark item
-- for the enforcement of that layering). This shipped `false` by default
-- when this section was written, pending its own go-live review; that
-- review has since happened and the flag now ships `true` above.
-- DEVELOPER_REFERENCE.md §6.7 names the variant set explicitly: "Radial bark options
-- (aggressive/alert/calm) each play a distinct sound asset attached to the
-- K9 entity" — that's the exact set shipped here, not an arbitrary pick
-- (DEVELOPER_REFERENCE.md#phase-5-research §1 confirms no other count is
-- named anywhere in the spec).
--
-- `sound` is still the SAME placeholder posture as client/main.lua's
-- BARK_SOUND_NAME/K9_SOUND_SET (see that file's header comment in full) —
-- none of these resolve to real, distinct authored audio yet.
-- DEVELOPER_REFERENCE.md#phase-5-research §1 confirms a real per-variant soundset needs
-- authored `.awc`/`dat151`/`dat54` RAGE-audio-bank assets, not just a
-- different string here — this table only carries the plumbing (which
-- placeholder name maps to which radial item/barkType), not the asset
-- itself. PlaySoundFromEntity with an unrecognized name/set combination is
-- a harmless no-op, so this ships safely with zero real audio, same as
-- Phase 1's single bark.
--
-- `barkType` is the exact string sent over the EXISTING
-- 'qbx_k9unit:server:relayBark' event (client/radial.lua) and echoed back
-- opaquely by server/main.lua's handler, which enforces
-- `BARK_TYPE_MAX_LENGTH = 16` — keep every `barkType` value below at or
-- under that length. server/main.lua itself is NOT modified for this
-- feature; it already accepts any opaque, length-capped string with no
-- enum validation.
-- ======================================================================
Config.AdvancedBarkRadial = {
    { barkType = 'bark_alert',      label = 'Alert Bark',      icon = 'triangle-exclamation', sound = 'Bark_Alert' },
    { barkType = 'bark_aggressive', label = 'Aggressive Bark', icon = 'skull',                sound = 'Bark_Aggressive' },
    { barkType = 'bark_calm',       label = 'Calm Bark',       icon = 'moon',                 sound = 'Bark_Calm' },
}

-- ======================================================================
-- K9 INVENTORY (ox_inventory stash). Backs
-- Config.Features.K9Inventory (still `false` above, per this resource's
-- "ship disabled until acceptance criteria are fully met" convention).
-- See DEVELOPER_REFERENCE.md §13.4.2 for the full security-critical integration
-- writeup this table backs, and server/inventory.lua's own header for the
-- concrete implementation (RegisterStash owner/groups derivation,
-- confidence-graded ox_inventory export notes). Transcribed from
-- DEVELOPER_REFERENCE.md §13.2's sketch, with `accessScope`'s Open Question (§13.4.2
-- item 1 / §13.6 item 3) RESOLVED below rather than left as a placeholder.
-- Every numeric value is still an unreviewed placeholder pending a
-- config-validator/economy-balance-agent pass (DEVELOPER_REFERENCE.md §9 item 4,
-- DEVELOPER_REFERENCE.md §13.5), same status every other Phase 3/4 sketch table in
-- this file carries — do not default Config.Features.K9Inventory to `true`
-- before that pass happens.
-- ======================================================================
Config.K9Inventory = {
    slots         = 5,
    maxWeight     = 8000,  -- grams-equivalent, same units ox_inventory's own item .weight fields use (unit convention confirmed: DEVELOPER_REFERENCE.md#contraband-search §1)
    interactRange = 2.0,

    -- 'department' is the ONLY supported value (coder-security finding,
    -- this pass — see server/inventory.lua's header "RESOLVED DESIGN
    -- DECISION" section for the full reasoning): any player whose job is a
    -- key in Config.Departments (any grade) may open a given K9's gear
    -- stash, shared-field-equipment framing, the same posture
    -- Config.K9Vehicles already gives patrol-vehicle trunk access.
    -- 'ownerOnly' was previously documented here as an equally-supported
    -- alternative -- it was NOT: ox_inventory's RegisterStash `owner`
    -- argument is never checked against the calling player's identity
    -- anywhere in ox_inventory's own open-inventory path (only `groups`
    -- is), so 'ownerOnly' provided no real access control at all.
    --
    -- CORRECTED (dead-config-field audit finding): this comment used to
    -- claim changing this value away from 'department' "will crash the
    -- resource on startup by design (assert, server/inventory.lua)". False
    -- -- server/inventory.lua's ResolveConfiguredAccessScope was
    -- deliberately changed from a hard assert to a WARN-AND-FORCE guard
    -- (see that file's own header "RESOLVED DESIGN DECISION" section) and
    -- explicitly "NEVER throws, NEVER aborts the caller". Setting this to
    -- anything other than 'department' does NOT crash this resource: at
    -- `onResourceStart` it prints one loud warning naming the bad value,
    -- silently forces this field back to 'department' for that session,
    -- and every K9 stash stays gated to department membership regardless.
    -- The old wording would have led an owner to believe a misconfigured
    -- value takes their server down; it actually self-corrects quietly.
    accessScope   = 'department',

    -- nil = no item whitelist enforced (ox_inventory's own slot/weight
    -- limits are the only restriction).
    --
    -- NOW ENFORCED. The note that stood here said this was deliberately not
    -- built, and warned an owner not to assume setting it did anything. That
    -- warning was correct when written and is now obsolete:
    -- server/inventory.lua enforces the list through ox_inventory's own
    -- `swapItems` hook.
    --
    -- Expects a plain array of item-name strings (same convention as
    -- Config.SearchContrabandItems). `nil` means no filtering, which stays the
    -- default -- an empty table would mean "allow nothing", a very different
    -- and much worse default to ship by accident.
    --
    -- Filters only what goes IN. Nothing is ever filtered on the way OUT, so a
    -- tightened list can never strand an item already in a stash -- that would
    -- be the unbounded trap this resource forbids.
    --
    -- The enforcement point was verified against ox_inventory's real source
    -- rather than assumed, because this resource has already shipped one
    -- illusory access control (an `accessScope` setting documented as
    -- restricting access that provided none). A hook returning false genuinely
    -- aborts before any mutation. If `registerHook` is unavailable on a given
    -- install, the stash still works unfiltered and logs one warning rather
    -- than silently pretending to filter.
    allowedItems  = nil,
}

-- ======================================================================
-- K9 MEDKIT (Config.Features.K9Medkit).
-- DEVELOPER_REFERENCE.md §13.4.4/§13.2. Item consumption + heal validation live in
-- server/medkit.lua; see that file's header for the full security-critical
-- writeup (mirrors server/search.lua's contraband-search trust boundary,
-- per that document's own explicit direction to reuse it as the template).
-- This shipped `false` by default when this section was written, pending
-- its own go-live review; that review has since happened and the flag now
-- ships `true` above. NUMERIC VALUES BELOW WERE UNREVIEWED PLACEHOLDERS at
-- that time, pending a config-validator/economy-balance-agent pass
-- (DEVELOPER_REFERENCE.md §9 item 4's scope, widened by DEVELOPER_REFERENCE.md §13.5) —
-- confirm that pass has actually happened before trusting these numbers on
-- a live server; this comment does not independently verify that it has.
-- ======================================================================
Config.K9Medkit = {
    itemName      = 'k9_medkit', -- PLACEHOLDER item name — must exist in the target server's ox_inventory items table; NOT registered as a hotbar-"useable" item by this resource, see server/medkit.lua's header for why
    healthRestore = 50,          -- native health units restored to the K9's REAL ped health, clamped to GetEntityMaxHealth server-side, never allowed to overheal
    injuryRestore = 40,          -- restores Config.Wellbeing.Injury's tracked value once server/wellbeing.lua (DEVELOPER_REFERENCE.md §13.1 sub-phase 4c/4d) exists — a no-op today, see server/medkit.lua's header
    range         = 2.0,         -- meters — server-enforced max distance between the using player and the target K9's own live positions, checked BEFORE any item consumption or health mutation
    cooldownMs    = 60000,       -- per-target (K9 citizenid) cooldown, prevents repeated instant-heal spam against the same K9
    -- Job names, in addition to any job ∈ Config.Departments, allowed to use
    -- this item on a K9 — mirrors DEVELOPER_REFERENCE.md §12.0 item 4's resolved
    -- "default metadata/job convention + override hook" pattern for the
    -- identical class of external-EMS-integration problem.
    emsJobs       = { 'ambulance' },
    -- IsMedkitUserAuthorizedOverride: function(usingPlayerServerId) -> boolean,
    -- OPTIONAL. Forward-looking override hook for a server whose EMS/
    -- qualification system isn't captured by a flat job-name list — left
    -- commented out until a server actually needs it, so it isn't mistaken
    -- for an active default. See server/medkit.lua's IsMedkitUserAuthorized.
    -- IsMedkitUserAuthorizedOverride = function(usingPlayerServerId) return false end,
}

-- ======================================================================
-- K9 WELLBEING (Config.Features.FatigueSystem / MoodSystem /
-- FearStressSystem / DistractionSystem / InjuryLimping). DEVELOPER_REFERENCE.md
-- §13.0 Decision 1 / §13.2 / §13.4.3: ONE shared config table, ONE shared
-- server/wellbeing.lua + client/wellbeing.lua pair, ONE shared per-citizenid
-- stat store and tick loop backing all five independently-gated stats --
-- mirrors Config.Tracking's existing Scent/Blood/Gunpowder precedent (three
-- independently-toggleable flags, one shared file pair). All five owning
-- flags shipped `false` by default when this section was written, pending
-- their own go-live/balance review; that review has since happened and all
-- five now ship `true` above. NUMERIC VALUES BELOW WERE UNREVIEWED
-- PLACEHOLDERS at that time, pending a config-validator/economy-balance-agent
-- pass (DEVELOPER_REFERENCE.md §9 item 4's scope, widened by
-- DEVELOPER_REFERENCE.md §13.5) -- individual fields below that have since
-- been confirmed wired/tuned say so in their own comment; treat any field
-- without such a note as still an unreviewed placeholder.
-- ======================================================================
Config.Wellbeing = {
    tickIntervalMs = 5000, -- ONE shared server-side decay/regen tick for all five stats -- see server/wellbeing.lua's header for why this beats five independent timers

    Fatigue = {
        max                     = 100,
        sprintDecayPerTick      = 2.0,  -- applied per tick while server-computed speed indicates sprinting
        idleRegenPerTick        = 1.0,  -- per tick while not sprinting
        restRegenPerTick        = 4.0,  -- WIRED. server/wellbeing.lua scans GetAllObjects()/GetAllVehicles() once per tick (shared across all K9s, not per-K9) for restSources models and applies this instead of idleRegenPerTick when a K9 is within restRadius and not sprinting. Positions are resolved server-side; a client can never claim to be resting. The "NOT WIRED THIS PASS" note that stood here was true when written.
        restRadius              = 5.0,
        -- The DETECTION is wired (see restRegenPerTick above -- the scan,
        -- the radius check and the server-side position resolution are all
        -- real). What is unverified is this MODEL NAME: 'water_bowl' is a
        -- guess that never got the two-independent-sources treatment
        -- prop_dog_cage_01 and prop_bodyarmour_02 got elsewhere in this
        -- file, so it may match nothing in the world. Confirm it on a dev
        -- server before enabling FatigueSystem, or the rest bonus simply
        -- never triggers -- silently, since a scan that matches nothing is
        -- indistinguishable from a K9 that is never near a rest source.
        -- WIRED IN THIS PASS (K9-can-rest-in-a-kennel task): added
        -- Config.DeployableKennel.propModel ('prop_dog_cage_01', ALREADY
        -- confirmed real -- see that field's own confidence note) as a
        -- second rest source, exactly the one-line addition this field's
        -- own CHANGELOG entry already anticipated. Deliberately did NOT add
        -- Config.DeployableKennel.fallbackPropModel here: that fallback is
        -- 'prop_tennis_ball', the SAME shared model server/kennel.lua's own
        -- header CROSS-FEATURE GAP section already documents colliding with
        -- server/fetch.lua's ball and server/propattachment.lua's fallback
        -- vest -- adding it here would make an unrelated dropped fetch ball
        -- or worn vest fallback prop silently grant the Fatigue rest bonus
        -- to any K9 standing near it. The primary model is unique to this
        -- feature; only it is listed.
        restSources             = { 'water_bowl', 'prop_dog_cage_01' },
        speedPenaltyThreshold   = 30,   -- fatigue below this value triggers the penalty
        -- RAISED 0.85 -> 0.90. These three wellbeing penalties MULTIPLY:
        -- client/movement.lua's own comment computes the worst case as
        -- Injury 0.7 * Fatigue 0.85 * Mood 0.9 ~= 0.535. That is the ordinary
        -- aftermath of one bad gunfight, and at those values an Elite K9
        -- (1.15x tier bonus) nets 0.615x -- SLOWER than a healthy Recruit.
        -- Three independently-reviewed "mild" penalties compounded into half
        -- speed because nobody reviewed them together. New worst case ~0.684.
        speedPenaltyMultiplier  = 0.90, -- fed into RecomputeK9MoveRate() (client/movement.lua, K9MoveRateModifiers.fatigue), never a standalone SetPedMoveRateOverride call
        -- NOT in DEVELOPER_REFERENCE.md §13.2's sketch verbatim -- added here
        -- because "sprinting" needs a concrete speed cutoff to classify
        -- from a server-side rolling position-sample (meters travelled per
        -- tick / tickIntervalMs). This file's own independent
        -- implementation of the general technique DEVELOPER_REFERENCE.md §12.5.2
        -- describes for NonLethalTakedown's speed gate (that document was
        -- not re-read this pass, per this session's file-scope boundary --
        -- reconcile against server/combat.lua's real implementation once
        -- Phase 3 lands, if the two ever need to agree exactly). Unreviewed
        -- placeholder like every other numeric value in this table.
        sprintSpeedThreshold    = 4.0,  -- meters/second, averaged over one tick interval

        -- NATIVE SPRINT STAMINA ASSIST (owner directive: "make sure high
        -- command can edit the ability to make stamina last longer or even
        -- permanently"). This is DELIBERATELY SEPARATE from the
        -- sprintDecayPerTick/speedPenaltyThreshold/speedPenaltyMultiplier
        -- fields above, which govern ONLY this resource's own custom
        -- Fatigue stat/speed-penalty. There is a SECOND, independent thing
        -- that limits how long a K9 can keep running: GTA/FiveM's own
        -- built-in player sprint-stamina mechanic (the same value
        -- client/hud.lua's "Stamina" HUD row displays via
        -- GetPlayerSprintStaminaRemaining) -- a real engine limit on the
        -- underlying Player, independent of ped model, that this resource
        -- previously never touched at all (confirmed: client/hud.lua only
        -- ever READ that native, nowhere in this resource was it ever
        -- restored/extended). Left at 0 (below), nothing about this changes
        -- -- vanilla stamina behaves exactly as it always has.
        -- Above 0, client/wellbeing.lua periodically calls the official
        -- RESTORE_PLAYER_STAMINA native (`RestorePlayerStamina(PlayerId(),
        -- percentage)` -- confirmed against FiveM's own natives.json,
        -- "Adds a percentage to a players stamina", officially documented
        -- with an example that calls it on a repeating timer for exactly
        -- this "keep it topped up" purpose) at this fraction, while the
        -- local player is an accessible K9. [0.0, 1.0] is this native's OWN
        -- documented valid range (1.0 = 100%) -- not an arbitrary ceiling
        -- picked for this task, the native's own contract. At 1.0, stamina
        -- is restored to full on every check interval, fast enough that it
        -- never has a real chance to visibly deplete -- effectively
        -- unlimited sprint for as long as this stays 1.0.
        nativeStaminaRestorePercent = 0.0,
    },
    Mood = {
        max                          = 100,
        damageDecayAmount            = 15,  -- flat decrement per logged damage event where the K9 itself is the victim (server/wellbeing.lua's own independent consumer of the relayDamageEvent relay server/tracking.lua also consumes)
        petRegenAmount               = 10,  -- per "Pet K9" ox_target interaction
        petCooldownMs                = 30000, -- per (interactor, target) pair -- stops repeat-pet spam
        feedRegenAmount              = 20,  -- per configured food item use
        feedItemName                 = 'k9_treat', -- PLACEHOLDER item name, needs to exist in the target server's ox_inventory items table
        -- RAISED 0.2 -> 1.0. This is the ONLY recovery path for a solo
        -- handler: server/wellbeing.lua rejects targetPed == usingPed for both
        -- Pet and Feed, so a K9 can never pet or feed itself. At 0.2 per 5s
        -- tick, Mood 0 -> full took ~42 minutes with nobody else online --
        -- long enough that most players would never see it move and would
        -- read the meter as broken. Now ~8.3 minutes, still leaving Pet/Feed
        -- (instant 10/20) clearly worth doing.
        passiveRegenPerTick          = 1.0,
        performancePenaltyThreshold  = 25,
        performancePenaltyMultiplier = 0.95, -- RAISED 0.9 -> 0.95, see Fatigue.speedPenaltyMultiplier's note on compounding. Fed into RecomputeK9MoveRate() (K9MoveRateModifiers.mood) -- resolves DEVELOPER_REFERENCE.md §13.4.3.2 open question 1 by taking reading (a), the document's own tentative recommendation (a movement-speed multiplier via the shared composer, not a success-chance penalty on a security-critical callback)
    },
    FearStress = {
        max                      = 100,
        gunfireRadius            = 20.0, -- meters -- reuses Phase 2's relayWeaponFire relay (server/tracking.lua also consumes it), new CONSUMER not new native
        gunfireLookbackSeconds   = 15,
        -- LOWERED 5.0 -> 3.0. At 5.0 with a 5s tick, continuous fire from ONE
        -- shooter crossed hesitationThreshold in ~70 seconds -- i.e. one
        -- ordinary firefight, which is precisely the situation BiteAndHold and
        -- NonLethalTakedown exist for. passiveDecayPerTick then needed ~6 more
        -- minutes to clear. See also the forgeability note on hesitationThreshold.
        risePerNearbyShotPerTick = 3.0,
        passiveDecayPerTick      = 1.0,
        -- RAISED 70 -> 85, alongside the rise-rate cut above.
        -- SECURITY, READ BEFORE ENABLING FearStressSystem TOGETHER WITH
        -- BiteAndHold OR NonLethalTakedown: server/combat.lua's
        -- ValidateCombatRequest rejects a bite/takedown while the K9
        -- IsHesitating(). Hesitation is driven by relayWeaponFire, which
        -- server/wellbeing.lua documents as deliberately payload-less and
        -- therefore FORGEABLE. That disclosure was written when nothing
        -- consumed IsHesitating(); combat.lua does now. So a hostile client
        -- can re-touch that event to lock out a specific K9's combat actions.
        -- CLOSED, and the wording here has been corrected: this comment used
        -- to say "indefinitely", which was true when written and is no longer.
        -- server/wellbeing.lua's HESITATION_MAX_CONTINUOUS_MS now caps any
        -- single continuous hesitation episode, forcing a real window in which
        -- ValidateCombatRequest is guaranteed to grant. What remains, and is
        -- disclosed rather than claimed closed, is that a forger who stays
        -- nearby can still cause repeated BOUNDED disruption.
        -- Two things worth carrying forward. First, the exploit was worse than
        -- its own original disclosure: once fearStress is primed, the renewal
        -- check re-extends hesitation every tick regardless of new input, so
        -- sustaining the lock cost roughly one forged event per minute, not
        -- the continuous spam the note assumed. Second, a forger targets
        -- ANOTHER player's K9 simply by standing within gunfireRadius of it --
        -- proximity to the victim, no relationship to the attacker required.
        -- Two correct reviews, one emergent hole in the seam between them.
        -- Tuning these numbers does NOT close it; the cap does.
        hesitationThreshold      = 85,
        hesitationDurationMs     = 8000,  -- how long a rejected Phase 3 combat-command attempt stays refused before the K9 may retry, absent a manual calm-down
        calmDownReduceAmount     = 40,    -- "Calm Down" command's effect (self-only, see server/wellbeing.lua)
        calmDownCooldownMs       = 15000,
    },
    Distraction = {
        flashbangImmune     = true, -- HALF IMPLEMENTED DELIBERATELY, AND SETTLED 2026-08-25 -- the missing half should stay missing; see the note below. server/wellbeing.lua exposes IsFlashbangImmune(citizenid) as a real callable accessor. What is deliberately NOT built is the consumer side: honouring immunity means listening to some third-party stun resource's event, whose name and payload shape are unknown, and fabricating a listener for an unnamed resource would look implemented and never fire. So a companion resource has something real to check, and this is still not a
        -- shipped guarantee on its own.
        -- RESEARCHED AND CLOSED, so this stops being reopened: the ecosystem has
        -- no dominant flashbang or stun resource to target. The popular ones are
        -- closed-source paid scripts -- unverifiable in principle, not merely
        -- unresearched -- and Qbox's own qbx_police ships no flashbang or taser
        -- at all, so there is no house implementation to piggyback on either.
        -- Of the two open-source candidates whose source was actually read, one
        -- reacts to a native game event AFTER the stun has landed (useless for
        -- prevention), and the other has a pre-effect gate that is an internal
        -- stub, not an export -- and FiveM resources do not share Lua global
        -- scope, so it cannot be overridden from outside regardless. Neither
        -- offers anything like ox_inventory's registerHook veto.
        -- Building a listener now would either never fire on a server not
        -- running that exact resource, or require maintaining a patch on
        -- someone else's niche script. Revisit only if a specific operator
        -- names the resource they actually run -- verifying one real contract
        -- is small and concrete; guessing generically is not.
        meatBaitItemName    = 'k9_meat_bait',      -- PLACEHOLDER
        meatBaitDurationMs  = 6000,
        meatBaitRadius      = 8.0,
        whistleItemName     = 'k9_ultrasonic_whistle', -- PLACEHOLDER
        whistleDurationMs   = 4000,
        whistleRadius       = 15.0,
        perTargetCooldownMs = 20000, -- stops the same K9 being re-distracted back-to-back
    },
    Injury = {
        max                     = 100,
        sprintBlockThreshold    = 30, -- below this, sprint input is blocked (client-local, see DEVELOPER_REFERENCE.md §13.0 Decision 3's disclosed bounded limitation)
        jumpBlockThreshold      = 20, -- below this, jump input is blocked
        speedPenaltyMultiplier  = 0.80, -- RAISED 0.7 -> 0.80, see Fatigue.speedPenaltyMultiplier's note on compounding. Fed into RecomputeK9MoveRate() (K9MoveRateModifiers.injury)
        damageDecayAmount       = 10, -- flat decrement per logged damage event -- independent value from Mood's own damageDecayAmount, same detection source
        -- RAISED 0.1 -> 1.0. K9Medkit was documented as "the intended
        -- primary recovery path," but at 0.1/tick a K9 dropped to 0 Injury
        -- (a handful of hits in one firefight, at damageDecayAmount 10 each)
        -- took ~16.7 real minutes to clear jumpBlockThreshold and ~25
        -- minutes to clear sprintBlockThreshold -- and client/wellbeing.lua
        -- HARD-BLOCKS sprint and jump input the entire time, with no server
        -- override. The medkit escape hatch also depends on an operator
        -- having actually registered Config.K9Medkit.itemName in their own
        -- ox_inventory, which this resource cannot guarantee (hence the new
        -- startup warning in server/wellbeing.lua). That combination is a
        -- stuck player, not a tuning choice. Same precedent and reasoning as
        -- Mood.passiveRegenPerTick's own 0.2 -> 1.0 raise above -- applied
        -- here because Injury's penalty is a hard INPUT BLOCK, a stronger
        -- case for parity than Mood's soft speed multiplier, not a weaker
        -- one. Now: jump clears in ~1.67 min, sprint in ~2.5 min, a full
        -- 0->100 climb in ~8.33 min, identical to Mood's adopted rate.
        passiveRegenPerTick     = 1.0,

        -- DEATH/RESPAWN RESTORE. Added to Injury the tick
        -- server/wellbeing.lua first observes a tracked K9's native health
        -- recover above its dead-health threshold after having been at or
        -- below it -- i.e. the K9 died and was revived. 100 = Injury.max, a
        -- FULL reset: the ped's real health is already restored to full by
        -- whatever laststand/ambulance system handles revival, so a virtual
        -- Injury value surviving that same event untouched was the real
        -- inconsistency.
        -- CONFIGURABLE: set to 0 to disable entirely (a supported no-op, for
        -- an operator who wants "still limping after respawn" for realism),
        -- or any value in [0, Injury.max] for a partial restore.
        -- DISCLOSED RESIDUAL RISK, restated 2026-08-25 after a red-team
        -- pass found the original wording understated it. What remains is:
        -- a player deliberately holding their K9's health at or below the
        -- dead-health threshold for at least MIN_DEATH_EPISODE_DURATION_MS
        -- (server/wellbeing.lua, ~60s at shipped defaults) and then healing
        -- normally, with no real ambulance or laststand flow required.
        -- That is bounded to a real minimum time cost per attempt and to
        -- ONE payout per episode -- never free, never unbounded.
        --
        -- What this fix already closed, and why the earlier wording here
        -- was wrong: the restore originally fired on ANY observed health
        -- crossing of the threshold, so an ordinary bandage after an
        -- ordinary hit paid a full Injury reset, and health oscillating
        -- during one genuine laststand could pay out several times. Both
        -- are now gated behind the minimum-duration check. The health
        -- transition itself is read SERVER-side and cannot be spoofed.
        --
        -- Note the duration gate is a code constant, not a config value,
        -- on purpose -- an operator-tunable minimum could simply be set
        -- low enough to reopen the exploit. Same reasoning as
        -- HESITATION_MAX_CONTINUOUS_MS elsewhere in that file.
        deathRespawnRestoreAmount = 100,
    },
}

-- ======================================================================
-- PROP ATTACHMENTS (Config.Features.PropAttachments) --
-- client/propattachment.lua, server/propattachment.lua. A visible prop
-- (vest/harness) attached to the K9 ped.
--
-- ABOUT boneIndex, because this is the part everyone gets wrong:
-- AttachEntityToEntity takes a bone INDEX, not a bone NAME, and the docs note
-- the index is "different to boneID". Three earlier research passes stalled
-- searching for a quadruped bone NAME, which does not exist to be found.
-- GetWorldPositionOfEntityBone is declared over a generic Entity (ENTITY
-- namespace, not PED), so it works against a dog ped -- but a dog skeleton's
-- layout differs from a human's, so the specific index has to be found by
-- looking. That is what Config.Features.BoneSweepDevTool exists for.
-- Default 0 is the root bone: always valid, never crashes, looks wrong.
-- ======================================================================
Config.PropAttachments = {
    -- UNVERIFIED. No confirmed lead for a K9 vest/harness prop was found, so
    -- this is a placeholder that will very likely not load. That is survivable
    -- by design: the fallback below is the one this actually degrades to.
    propModel         = 'prop_bodyarmour_02',
    -- The SAME model Config.DeployableKennel already falls back to, chosen for
    -- exactly that reason -- it is the one prop in this resource with a
    -- confirmed-safe track record rather than a second unverified guess. It
    -- will look wrong (a K9 wearing a tennis ball), which is the point: an
    -- obviously-wrong visible prop tells an operator to go find a real vest
    -- model, where a silent no-op would just look like the feature is broken.
    fallbackPropModel = 'prop_tennis_ball',
    boneIndex         = 0,                    -- root; replace after a dev-server sweep
    offsetX = 0.0, offsetY = 0.0, offsetZ = 0.0,
    rotX    = 0.0, rotY    = 0.0, rotZ    = 0.0,
    toggleCooldownMs         = 2000,
    pendingConfirmTtlMs      = 15000,
    confirmDistanceTolerance = 5.0,
}

-- ======================================================================
-- BONE SWEEP DEV TOOL (Config.Features.BoneSweepDevTool) -- see that flag's
-- own comment. Dev servers only.
-- ======================================================================
Config.BoneSweepTool = {
    -- Authorization is deliberately a SEPARATE, stricter principal from the
    -- audit commands' own `auditGrade`: granting someone read-only audit
    -- access must not also hand them a tool that spawns and attaches props.
    -- server/bonetool.lua therefore grants on `job.isboss` ONLY -- no numeric
    -- grade branch -- so there is no key to set here. The former
    -- `AcePermission = 'k9unit.bonesweep'` was removed on 2026-08-25 when
    -- that file dropped IsPlayerAceAllowed.
    TestPropModel     = 'prop_tennis_ball',
    MaxBoneIndex      = 200,
    TestOffsetX = 0.0, TestOffsetY = 0.0, TestOffsetZ = 0.0,
    CommandCooldownMs = 500,
}

-- ======================================================================
-- FETCH (Config.Features.FetchMechanic) -- client/fetch.lua, server/fetch.lua.
--
-- Note what this feature is NOT: the K9 does not walk the ball back on its
-- own. It cannot -- the K9 is a connected player's own character, and nothing
-- in this resource's architecture scripts a player's ped movement. The return
-- leg is a real player action ("Deliver to Handler", server-validated for
-- identity and live proximity) instead of a scripted walk.
-- ======================================================================
Config.FetchMechanic = {
    ballPropModel                = 'prop_tennis_ball',
    throwForwardOffsetMeters     = 1.0,
    throwUpOffsetMeters          = 1.2,
    throwForceForward            = 12.0,
    throwForceUp                 = 6.0,
    throwCooldownMs              = 5000,
    pendingThrowTtlMs            = 15000,
    maxBallLifetimeMs            = 300000, -- absolute ceiling; no ball outlives this
    -- ENFORCED SERVER-SIDE, not just as an ox_target radius. A red-team pass
    -- found this value was previously only the client's ox_target `distance`
    -- field -- pure UI -- so requestPickupFetchBall accepted a pickup from
    -- anywhere on the map. Any player with K9 access could take another
    -- player's ball remotely and then re-drop it at their own position.
    -- server/fetch.lua now re-measures live distance against this, the way
    -- requestDeliverFetchBall always did.
    pickupInteractDistanceMeters = 2.0,

    -- Pickup had NO rate limit before; only the initial throw did, which is
    -- what made the remote-steal loop freely repeatable. server/fetch.lua
    -- falls back to 500 if this is absent, so removing it degrades safely
    -- rather than removing the throttle.
    -- There is deliberately no releaseCooldownMs counterpart: voluntary
    -- release is an escape hatch, and NewCooldown treats a non-positive
    -- threshold as permanently-on rather than off, so a `0` here meant to
    -- disable the throttle would instead disable releasing. See
    -- server/fetch.lua's releaseFetchBall doc comment.
    pickupCooldownMs             = 500,
    deliverProximityMeters       = 3.0,
    maintenanceIntervalMs        = 2000,

    -- 'fake' (delete + animate) or 'attach' (real mouth-carried prop).
    -- Ships 'fake' deliberately: 'attach' is only honest once a dev-server
    -- sweep has found a real mouth/jaw index AND confirmed it does not clip
    -- during the bark/pant carry pose. The feature is fully playable in
    -- 'fake' mode without that step.
    mouthCarryMode = 'fake',
    mouthBoneIndex = 0, -- root; replace from a sweep, then set mouthCarryMode
    mouthOffsetX = 0.0, mouthOffsetY = 0.4, mouthOffsetZ = 0.15,
}

-- ======================================================================
-- PROXIMITY AUDIO (Config.Features.ProximityAudioFX) -- client/proximityaudio.lua.
-- Distance-scaled K9 audio over the NUI bridge's Web Audio gain node.
-- UPDATED 2026-08-25: this used to say no audio ships with this resource.
-- That is no longer true. html/sounds/growl_ambient.ogg -- the sound THIS
-- feature plays -- ships, is listed in fxmanifest.lua's files{} block, and
-- is credited with its licence in html/sounds/CREDITS.md. A sound key with
-- no file still degrades to silence rather than erroring, which looks
-- exactly like the feature being off, so keep that list complete.
-- ======================================================================
Config.ProximityAudioFX = {
    scanIntervalMs  = 2500,  -- discovery cadence; never a per-frame loop
    triggerDistance = 25.0,  -- meters; must stay <= client/audio.lua's own 30.0 ceiling
    soundName       = 'Growl_Ambient', -- resolves to html/sounds/growl_ambient.ogg
}


-- ======================================================================
-- RESOURCE AUTO-DETECTION / COMPATIBILITY (Config.Features.ResourceAutoDetect)
-- shared/compat/*.lua
--
-- PLAIN ENGLISH, READ THIS FIRST:
-- Every server runs a different mix of scripts. One runs ox_inventory,
-- another runs qb-inventory, another wrote their own from scratch. The same
-- goes for dispatch, for the ambulance/downed script, and for the "press E"
-- targeting script. This block is how this resource stops guessing and
-- starts ASKING your server what it actually runs.
--
-- HOW IT WORKS, IN THREE STEPS:
--   1. When the server starts, this resource walks the `candidates` list for
--      each system below IN ORDER and picks the FIRST one that is actually
--      started on your server. First match wins, so put your preferred one
--      earlier in the list.
--   2. It then checks that the one it picked really has the functions this
--      resource needs. A resource that is running but is an old/renamed
--      version fails this check and is SKIPPED, and detection moves on to
--      the next candidate rather than silently half-working.
--   3. Whatever it settled on is printed to your server console once, at
--      startup, and can be reprinted at any time in game with /k9compat.
--
-- THE THREE THINGS YOU CAN SET, per system:
--   * `override`   -- a resource name, as a string. Skips detection entirely
--                     and uses THIS one. Use it when you run two of
--                     something and want to be certain which one is used.
--                     Setting the INVENTORY system's override (or letting
--                     auto-detect pick it) to 'qb-inventory' specifically
--                     has two real gaps that print no warning -- read the
--                     INVENTORY section below before you choose it.
--   * `candidates` -- the search order. ADD YOUR OWN NAME TO THIS LIST if
--                     you run something not listed. It is a plain list of
--                     strings; there is nothing magic about the ones that
--                     ship here.
--   * `custom`     -- YOUR OWN CODE. A table of functions, written by you,
--                     that beats everything above -- override included. This
--                     is the escape hatch for a fully custom, in-house
--                     script that nothing else could possibly know about.
--                     See DEVELOPER_REFERENCE.md §21 for the exact function
--                     list each system expects, with a copy-paste template.
--
-- WHAT HAPPENS IF NOTHING IS FOUND: the feature that needed that system
-- degrades to a clean no-op -- one clear console line naming the system and
-- what it disabled, then silence. It never errors in a loop, never blocks
-- resource start, and never takes the rest of the resource down with it.
-- Nothing here is a hard dependency EXCEPT what fxmanifest.lua's own
-- `dependencies` block already lists.
--
-- SECURITY NOTE, do not undo this: detection NEVER grants permission.
-- Every rank, certification and ownership check in this resource runs on
-- the server and is completely independent of which external script was
-- detected. A hostile or broken third-party inventory can make a feature
-- stop working; it cannot make a player a K9, mint XP, or bypass a rank.
-- ======================================================================
Config.Compat = {
    -- Master switch for the whole detection pass. `false` means "use only
    -- what I set by hand in `override`/`custom` below, detect nothing."
    autoDetect = true,

    -- Print one summary block to the server console at startup listing what
    -- was found for each system. Recommended: leave this on. It is the
    -- single fastest way to answer "why is X not working on my server".
    logDetectionOnStart = true,

    -- In-game command that reprints that same summary on demand, to whoever
    -- runs it, plus WHY each candidate was skipped. Gated to the same high
    -- command rank as the rest of the admin surface (Config.Departments
    -- `highCommandGrade`) -- it names the scripts your server runs, which is
    -- not something to hand to every player. Set to `false` to not register
    -- the command at all.
    diagnosticCommand = 'k9compat',

    -- Re-run detection when a resource starts or stops while the server is
    -- already up, so `restart ox_inventory` (or swapping inventories on a
    -- live server) is picked up without a full server restart.
    redetectOnResourceRestart = true,

    -- How long to wait, at startup, for a candidate that is still starting
    -- before giving up on it. Resource start order is not guaranteed, so a
    -- flat zero here would make detection a coin flip on a busy server.
    startupGraceMs = 10000,

    Systems = {
        -- ==============================================================
        -- INVENTORY -- items, stashes, the contraband search, the K9 supply
        -- shop, and the tablet item. The most-used system in this list.
        --
        -- IF YOU PICK (OR AUTO-DETECT) qb-inventory, READ THIS FIRST. Two
        -- specific things behave differently on qb-inventory than on
        -- ox_inventory (the one this resource is built and tested against),
        -- and neither one prints a warning or an error when it happens:
        --   * The K9 supply shop does not open for players. A handler who
        --     clicks "Buy K9 Gear" gets nothing at all -- no menu, no
        --     message, nothing in the server console. qb-inventory has no
        --     way for this resource to open a shop screen from the
        --     PLAYER's side, only from the server's side, so this one
        --     action is a permanent dead end on qb-inventory -- not
        --     something a restart or a different setting fixes.
        --   * A search cannot see contraband hidden inside a bag or
        --     backpack item. It still correctly finds anything sitting
        --     loose in someone's own inventory ("pockets"); only the
        --     INSIDE of a separate bag item is invisible to it on this
        --     backend. A "clean" result can mean "actually clean" or
        --     "hidden in a bag" on qb-inventory -- there is no way to tell
        --     which.
        -- Everything else -- including the K9 medkit and finding
        -- contraband sitting loose (not in a bag) -- works normally on
        -- qb-inventory. If you need the supply shop to work for players,
        -- or need bag-searching to be reliable, use ox_inventory instead.
        -- ==============================================================
        inventory = {
            override = nil,
            candidates = {
                'ox_inventory',      -- the one this resource was built against
                'qs-inventory',
                'qb-inventory',
                'ps-inventory',
                'origen_inventory',
                'codem-inventory',
                'core_inventory',
                'tgiann-inventory',
            },
            custom = nil,
        },

        -- ==============================================================
        -- TARGET -- the "look at a thing and press E" menus. Every walk-up
        -- interaction this resource adds goes through here.
        -- ==============================================================
        target = {
            override = nil,
            candidates = {
                'ox_target',
                'qb-target',
                'qtarget',
                'interact',
                'sleepless_interact',
            },
            custom = nil,
        },

        -- ==============================================================
        -- FRAMEWORK -- who a player is: their citizen id, their job, their
        -- rank. This is the one system this resource genuinely cannot run
        -- without, because every permission check in it reads a job rank.
        --
        -- READ THIS BEFORE YOU TRUST THE LIST BELOW. Auto-detection is real
        -- and works for your inventory and your targeting script -- swap
        -- either of those and this resource adapts. **Framework is the
        -- exception, and right now it does not work that way.** The
        -- qb-core and es_extended entries below are researched and correct
        -- as far as they go, but only one file in this entire resource
        -- actually routes through them. Everything else -- certifications,
        -- permissions, the tablet, XP, combat -- calls Qbox directly, at an
        -- ESTIMATED number of places that this comment does not keep
        -- current (a single `grep -rn 'exports\.qbx_core'` already turns up
        -- 200+ and counting as the resource grows -- do not cite a fixed
        -- number here again; recount at the time you need it). Qbox is also
        -- a hard requirement in fxmanifest.lua, so FiveM will not start
        -- this resource without it.
        --
        -- What that means in practice: if you run qb-core or ESX, detection
        -- will correctly identify it, and the resource still will not work.
        -- Do not read this list as a compatibility promise.
        --
        -- This is written down rather than quietly fixed because making it
        -- true is a large job (converting every one of those direct-call
        -- sites, whatever the current count is), not a small one, and it is
        -- your call whether it is worth doing. It is recorded in KNOWN_ISSUES.md
        -- as a decision waiting on you.
        -- ==============================================================
        framework = {
            override = nil,
            candidates = {
                'qbx_core',
                'qb-core',
                'es_extended',
            },
            custom = nil,
        },

        -- ==============================================================
        -- DISPATCH -- OUTBOUND ONLY. This resource ANNOUNCES things (for
        -- example, "a K9 went down"); it never asks dispatch a question.
        -- Even with nothing detected here, every announcement still fires
        -- as a plain `qbx_k9unit:events:*` event that your own dispatch can
        -- listen for with one line of code -- so a fully custom dispatch
        -- needs NOTHING in this block.
        --
        -- READ THIS BEFORE YOU ASSUME EVERYTHING SHOWS UP ON YOUR DISPATCH
        -- BOARD. Detection here only lights up a real, no-setup-needed
        -- board alert for ONE thing today: a K9 going down. A
        -- search-and-rescue call being completed, and a contraband search
        -- finishing, both still fire their own plain event (so something
        -- IS available to listen for), but neither one automatically posts
        -- to a detected dispatch board the way a K9 going down does. This
        -- is a deliberate, narrower scope, not a bug that got missed. If
        -- you want search-and-rescue calls or search results to show up on
        -- your dispatch board too, someone needs to write a small bridge
        -- that listens for that event and posts it to your dispatch
        -- script -- this resource does not do that step for you today.
        -- ==============================================================
        dispatch = {
            override = nil,
            candidates = {
                'ps-dispatch',
                'cd_dispatch',
                'qs-dispatch',
                'rcore_dispatch',
                'core_dispatch',
                'linden_outlawalert',
            },
            custom = nil,
        },

        -- ==============================================================
        -- AMBULANCE / DOWNED -- INBOUND. Answers one question: "is this
        -- player dead or downed right now?" Used so a K9 cannot bite or
        -- drag someone who is already on the floor.
        --
        -- NOTE: `Config.Combat.PropDragging.IsPlayerDownedOverride` still
        -- exists and still WINS over anything detected here. That hook was
        -- the original answer to this problem and is not being retired --
        -- if you already wrote one, it keeps working exactly as before.
        -- ==============================================================
        ambulance = {
            override = nil,
            candidates = {
                'qbx_medical',
                'qb-ambulancejob',
                'ps-ambulancejob',
                'wasabi_ambulance',
                'esx_ambulancejob',
            },
            custom = nil,
        },
    },
}


-- ======================================================================
-- K9 LEADERBOARD (Config.Features.K9Leaderboard) -- server/leaderboard.lua.
-- The /k9stats command. Both values below have built-in fallbacks, so a
-- missing or nonsensical entry prints one clear console line and keeps
-- working rather than breaking the command.
-- ======================================================================
Config.Leaderboard = {
    -- How many places to show. server/leaderboard.lua enforces its own hard
    -- ceiling on top of this, so raising it past that ceiling is capped
    -- rather than obeyed -- the query reads exactly this many rows off an
    -- index, so it stays cheap no matter how big the table gets.
    MaxRows = 20,

    -- Minimum gap between one player's own /k9stats runs, in milliseconds.
    -- MUST BE POSITIVE. Zero or negative does NOT mean "no cooldown" in
    -- this codebase -- the shared cooldown helper treats a non-positive
    -- threshold as PERMANENTLY ON, which would lock the command out for
    -- everyone, forever, with nothing logged to explain why.
    CommandCooldownMs = 5000,
}

-- ======================================================================
-- TRAINING MODE (Config.Features.TrainingMode) -- server/training.lua and
-- client/training.lua.
--
-- A practice yard. Stand inside one of the areas below, run /k9training,
-- and you can rehearse the search and bite-and-hold flow against a
-- scripted dummy. It never touches a real player, never reads anyone's
-- real inventory, and awards NO XP at all -- so it is safe to leave on.
--
-- YOU ALMOST CERTAINLY NEED TO EDIT THE COORDINATES BELOW. The single
-- entry that ships is a placeholder near Mission Row PD -- a starting
-- point, not a surveyed spot on your map. Stand where you want the yard,
-- note your coordinates, and replace them.
-- ======================================================================
Config.TrainingZones = {
    { label = 'LSPD K9 Training Yard', x = 441.8, y = -981.7, z = 30.7, radius = 20.0 },
    -- Add as many as you like:
    -- { label = 'Sandy Shores Sheriff Yard', x = 1853.2, y = 3689.4, z = 34.3, radius = 25.0 },
}

Config.Training = {
    -- Minimum gap between turning training mode on and off again, and
    -- between one practice rep and the next, in milliseconds. BOTH MUST BE
    -- POSITIVE. Zero or negative does NOT mean "no cooldown" in this
    -- codebase -- the shared cooldown helper treats a non-positive
    -- threshold as PERMANENTLY ON, which would lock the feature out for
    -- everyone, forever, with nothing logged to explain why.
    ToggleCooldownMs = 3000,
    ActionCooldownMs = 4000,

    -- How often a practice search comes back as a "find" rather than
    -- "clean", from 0.0 (never) to 1.0 (always). A coin flip so trainees
    -- see both outcomes. It decides nothing real and pays nothing.
    ContrabandFoundChance = 0.5,
}

-- ======================================================================
-- K9 SUPPLY SHOP (Config.Features.K9EquipmentShop) -- server/equipmentshop.lua
-- and client/equipmentshop.lua.
--
-- THE ITEMS BELOW MUST ALREADY EXIST IN YOUR INVENTORY SCRIPT. This
-- resource cannot create items -- only your inventory's own items list
-- can. Any name here that your inventory does not know is skipped with a
-- clear console warning naming it, and if every item is unknown the shop
-- is not registered at all rather than appearing empty.
--
-- YOU ALMOST CERTAINLY NEED TO EDIT `locations`. The coordinate that ships
-- is a placeholder near Mission Row PD, not a surveyed spot on your map.
-- Stand where you want the counter, note your coordinates, replace it. An
-- empty `locations` list means the shop is registered but has nowhere to
-- be opened from, which reads as the feature being broken.
--
-- WHO CAN SHOP: everyone in a department listed in Config.Departments, at
-- any grade. That is derived automatically -- there is no separate job
-- list to keep in sync here.
-- ======================================================================
Config.K9EquipmentShop = {
    -- The internal key your inventory files this shop under. Change it
    -- only if it collides with a shop you already run.
    shopType = 'k9supply',

    -- What officers see as the shop's name. Also the default prompt label
    -- for every location below that does not set its own.
    label = 'K9 Supply',

    -- Which ITEM is spent as money. This is an item name your inventory
    -- already tracks -- conventionally 'money' -- NOT a banking resource.
    -- Nothing here ever calls a bank.
    currencyItem = 'money',

    -- ==================================================================
    -- THE SHOP DOG. The walk-up point is a real, visible ped you approach,
    -- not an invisible patch of ground. The four fields below are the
    -- defaults for every location; any single location can override them.
    -- This is a shop attendant, not a K9 -- ANY streamed model works,
    -- including one that never appears in Config.Peds.
    -- ==================================================================

    -- Default model for the shop ped.
    pedModel = 'a_c_shepherd',

    -- Default direction it faces, in degrees.
    pedHeading = 0.0,

    -- What it does while standing there. Set to false and it just stands.
    -- The default is a verified sitting-dog animation; if you change
    -- pedModel to something that is not a dog, change this too.
    pedScenario = 'WORLD_DOG_SITTING_SHEPHERD',

    -- How long to wait for a shop ped's model to load before giving up, in
    -- milliseconds. On timeout that ONE location is skipped with a console
    -- warning -- the shop does not hang and the other locations still work.
    pedModelLoadTimeoutMs = 10000,

    -- Where the shop dogs stand. PLACEHOLDER -- see the note above. Add,
    -- remove or reorder entries freely; no code change is needed, and high
    -- command can also do it live from the tablet. Any entry may set its
    -- own `model`, `heading`, `scenario` or `label` to override the
    -- defaults above for that one spot only.
    locations = {
        { x = 452.1, y = -980.1, z = 30.7 },
        -- { x = ..., y = ..., z = ..., model = 'a_c_husky', heading = 180.0, label = 'K9 Supply (Vespucci)' },
    },

    -- Prices are in whatever `currencyItem` is. Tune freely; these are
    -- starting numbers, not balance guidance.
    items = {
        { name = 'k9_medkit',             price = 250 },
        { name = 'k9_treat',              price = 25 },
        { name = 'k9_meat_bait',          price = 40 },
        { name = 'k9_ultrasonic_whistle', price = 150 },
    },
}

-- ======================================================================
-- SCENT TRAIL HUNT (Config.Features.ScentTrailHunt) -- PROJECT_HISTORY.md §2.
-- client/scenttrail.lua + server/scenttrail.lua.
--
-- Different from the scent tracking above, and deliberately so: that one
-- reveals a location and draws a trail to it. This one reveals NOTHING.
-- The hiding spot's coordinates never leave the server -- the player's
-- game is only ever told how far away they are, which is what paces the
-- growl. So there is nothing in the player's game to read the answer out
-- of. It awards no XP either.
-- ======================================================================
Config.ScentTrailHunt = {
    -- How far from the K9 the hidden spot can be, in meters.
    minRadius         = 10.0,
    maxRadius         = 30.0,

    -- How close counts as finding it. Measured flat, ignoring height.
    arrivalRadius     = 3.0,

    -- How often the growl checks distance when far away, in milliseconds.
    -- Close in, it speeds up to a fixed rate that is not configurable.
    pollIntervalMs    = 2000,

    -- Minimum gap between one hunt and the next, per player, in
    -- milliseconds. MUST BE POSITIVE -- a non-positive value here does NOT
    -- mean "no cooldown"; the shared cooldown helper treats it as
    -- PERMANENTLY ON and the feature locks out for everyone, forever.
    startCooldownMs   = 8000,

    -- A hunt nobody finishes gives up after this long, in milliseconds
    -- (five minutes). This is what stops a forgotten hunt lasting all
    -- session.
    maxHuntDurationMs = 300000,
}

-- ======================================================================
-- DATABASE (Config.Database) -- whether this resource is allowed to talk
-- to a database at all.
--
-- READ THIS EVEN IF YOU DO NOT CODE. With `enabled = false` you do NOT
-- need to run ANY of the .sql files in the sql/ folder -- not
-- install.sql, not a single migration. Every feature still works
-- tonight, for everyone on the server right now. The trade is memory,
-- not features: certifications, XP, partnerships, permission grants,
-- tablet theming and K9 appearance are held in the server's memory only,
-- for as long as it keeps running. The moment it restarts -- a crash, an
-- update, a scheduled reboot -- all of it is gone and everyone starts
-- over. Dogs forget who trained them, handlers lose their rank and XP,
-- partners are un-paired, the tablet theme resets. Nothing is corrupted
-- and nothing crashes. It simply never remembers past today.
--
-- ONE THING THIS DOES NOT TURN OFF: `oxmysql` must still be installed and
-- started as its own resource. This resource declares it as a hard
-- dependency, and FXServer refuses to START qbx_k9unit without it --
-- that check happens before this file is ever read, so no setting here
-- can route around it. `enabled = false` means this resource never sends
-- oxmysql a single query and needs none of its own tables to exist. If
-- you run no database at all, you still need the oxmysql resource
-- present, pointed at any reachable database.
--
-- THIS IS NOT THE RECOMMENDED WAY TO RUN THIS. It is here for someone
-- who genuinely does not want to do a database import, for a trial
-- server, or for a test before committing to a real install. If you can
-- run sql/install.sql, do -- your handlers keep what they earned.
--
-- PERMANENTLY LOST, not merely delayed: THE AUDIT TRAIL. No record of
-- who certified whom, no search log -- "did this K9 really search my
-- car" -- and no permission-grant history. If a dispute comes up there
-- is nothing to check. Not a smaller record. None. Most police servers
-- decide that alone is worth running the database for.
--
-- A SAFETY RULE THE CODE FOLLOWS SO YOU DO NOT HAVE TO THINK ABOUT IT:
-- with this off, nobody ever ends up with MORE access than they would
-- have on a database-backed server. A memory-only grant can only be
-- easier to LOSE than a saved one, never easier to get.
-- ======================================================================
Config.Database = {
    -- true (recommended, and the default) saves certifications, XP,
    -- partnerships, permissions, runtime overrides, tablet theming and K9
    -- appearance so they survive a restart. false means none of that is
    -- ever read from or written to a database -- it lives in memory for
    -- this server session only. See the block above for what that costs.
    enabled = true,
}

-- ======================================================================
-- PURSUIT SPRINT (Config.Features.PursuitSprint) -- PROJECT_HISTORY.md §5.
-- client/pursuitsprint.lua + server/pursuitsprint.lua.
--
-- A short burst where the dog is genuinely faster than the person running
-- from it. This is the most PvP-affecting thing in this resource, so it is
-- deliberately narrow: a wanted target only, a few seconds only, and a
-- cooldown between bursts. It is meant to END a foot chase that was
-- already going the K9's way, not to make escape impossible.
--
-- ON THE SPEED NUMBER: the game clamps the COMBINED effect of every speed
-- influence -- breed, XP tier, tiredness, and this burst -- to at most
-- twice normal. So even a wildly mis-set number here cannot produce
-- something faster than that ceiling. Raise it if you like; you will hit
-- the ceiling before you break anything. At the numbers below a K9 is
-- sprinting roughly 11% of the time -- a burst that finishes a chase
-- already going their way, not a standing speed advantage.
-- ======================================================================
Config.PursuitSprint = {
    -- How much faster than normal, during the burst. 1.0 is no change.
    speedMultiplier = 1.4,

    -- How long a burst lasts, in milliseconds.
    durationMs = 5000,

    -- Minimum gap between one burst and the next, per player, in
    -- milliseconds. MUST BE POSITIVE -- a non-positive value does NOT mean
    -- "no cooldown" here; the shared cooldown helper treats it as
    -- PERMANENTLY ON and the ability locks out for everyone, forever.
    cooldownMs = 45000,

    -- How close the K9 must be to the target to start a burst, in meters.
    requestRangeMeters = 20.0,
}

-- ======================================================================
-- SCENT LINEUP (Config.Features.ScentLineup) -- PROJECT_HISTORY.md §4.
-- server/scentlineup.lua + client/scentlineup.lua.
--
-- "Sniff the row and pick the match." A K9 invites several online players
-- to stand in a line. Every one of them has to accept -- nobody is pulled
-- into this without agreeing. The moment the last invite is accepted the
-- SERVER secretly picks one of them at random, and tells NOBODY, not even
-- the K9 running the drill, until a single final guess is committed. So
-- there is nothing in anyone's game to read the answer out of.
--
-- It awards no XP, on purpose: the outcome is random and you could run it
-- all day with a group of willing friends, which is exactly the shape of
-- XP farm this resource has already had to close eight times.
-- ======================================================================
Config.ScentLineup = {
    -- Fewest OTHER players a lineup may contain, not counting the K9
    -- running it. Below this there is no real guess to make.
    minParticipants = 2,

    -- Most other players in one lineup, so a single K9 cannot tie up a
    -- large share of everyone online.
    maxParticipants = 6,

    -- How long the invited group has to ALL accept before the whole thing
    -- cancels and everyone is freed, in milliseconds.
    inviteWindowMs = 30000,

    -- Once everyone has accepted, how long the K9 has to commit their one
    -- guess before it cancels, in milliseconds.
    pickWindowMs = 240000,

    -- Minimum gap between one K9 starting a lineup and starting another,
    -- in milliseconds.
    startCooldownMs = 60000,
}

-- ======================================================================
-- SEARCH AND RESCUE CALLS (Config.Features.SARCalls) -- PROJECT_HISTORY.md §3.
-- client/sarcalls.lua + server/sarcalls.lua.
--
-- Dispatch hands the K9 a missing-person or lost-property call. Somewhere
-- nearby, the server hides a target and tells nobody where -- the officer
-- only gets their dog reacting more strongly as they get closer. Find it
-- and the call resolves as a rescue: nobody is arrested, nothing bad
-- happens to anyone.
--
-- The "missing person" is always scenery -- an NPC that appears only once
-- the call is already solved, on the finder's own screen. It is never a
-- real player, so nobody can be volunteered into one without agreeing.
-- ======================================================================
Config.SARCalls = {
    -- How far from the officer the hidden target may be placed, in meters.
    -- The minimum is doing real work here: it guarantees a genuine walk no
    -- matter how often calls are taken, which is what stops this becoming
    -- an XP treadmill.
    minRadius = 40.0,
    maxRadius = 90.0,

    -- How close counts as finding it, in meters. Measured on the server
    -- from the officer's real position, never from anything their game
    -- claims.
    arrivalRadius = 6.0,

    -- How strongly the dog reacts, by distance in meters. A new reaction
    -- only fires when the officer crosses one of these lines, not
    -- continuously.
    burningDistance = 8.0,
    hotDistance     = 20.0,
    warmDistance    = 45.0,

    -- How often the server re-checks distance, in milliseconds.
    pollIntervalMs = 2000,

    -- How long an unsolved call lasts before it gives up, in milliseconds
    -- (eight minutes). A call that times out costs nothing and grants
    -- nothing -- an honest "came up empty", exactly like a real search
    -- that finds nothing.
    maxCallDurationMs = 480000,

    -- Minimum gap between one officer taking a call and taking another, in
    -- milliseconds (ten minutes). This is on REQUESTING a call, not on
    -- finishing one.
    startCooldownMs = 600000,

    -- What the "we found them" moment looks like. Scenery only, drawn on
    -- the finder's own screen after the call has already resolved, then
    -- cleaned up by that same screen. The person model is the standard
    -- multiplayer character, which every player already has loaded --
    -- deliberately not a themed model this resource cannot guarantee your
    -- server streams.
    missingPersonPedModel = 'mp_m_freemode_01',
    lostPropertyPropModel = 'prop_tennis_ball',
    revealDurationMs = 15000,
}
