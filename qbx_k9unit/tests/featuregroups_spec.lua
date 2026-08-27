--[[
    tests/featuregroups_spec.lua

    Owner-directed escalation, verbatim: "Merging the features should be
    more on a fundamental basis" -- Config.FeatureGroups (config.lua) is
    the nested capability tree that replaced label-only grouping
    (commit d00fd60) with a REAL structural effect: a parent's
    `enabled = false` forces every one of its children off, regardless of
    that child's own value. FEATURE_STRUCTURE_SPEC.md is the full design
    writeup; this file is the guarantee that design never silently rots or
    regresses on a real server.

    Five things this file exists to prove, matching the task's own
    non-negotiables:
      1. NO-OP ON DEFAULTS -- the shipped Config.FeatureGroups resolves to
         EXACTLY today's shipped Config.Features values, for all 60 keys,
         including the four that ship `false`.
      2. NEVER SILENTLY RE-ENABLE -- covered by (1) plus an explicit named
         check on the four ships-false keys.
      3. DRIFT GUARD -- every real Config.Features key is accounted for by
         exactly one family or the standalone list (this is the exact
         mechanism that would have caught HungerThirstSystem landing
         mid-session with no home in this tree, before it became a real
         gap).
      4. PARENT-OFF FORCES CHILDREN OFF, and PARENT-OFF REFUSES A LIVE
         CHILD-ON OVERRIDE (IsFeatureGroupParentEnabled) -- the actual
         structural effect the owner asked for, not just a label.
      5. CLAMP AND WARN, NEVER ASSERT, and SILENT ON THE NORMAL PATH -- a
         valid config prints nothing at all; a malformed one warns and
         falls back; old flat-shape configs are untouched.

    Never a hand-typed duplicate of Config.Features' own key list or
    values (same discipline tests/tabletfeaturedomains_spec.lua's own
    header already establishes) -- every assertion below reads the REAL
    config.lua, loaded fresh, and Config.FeaturesBeforeGrouping (also
    real, captured by the real ResolveFeatureGroups on its own first call)
    as the one and only source of truth for "what did this used to say".
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Loads a fresh copy of the REAL config.lua into its own throwaway
--- sandbox, with print captured (never real stdout) so tests can assert
--- on exactly what did or did not get printed. A FRESH env per call,
--- deliberately -- several tests below mutate Config.FeatureGroups and
--- re-invoke ResolveFeatureGroups(), and a fresh load per test is what
--- keeps one test's mutation from ever leaking into another's baseline.
--- @return table env
--- @return table printLog
local function loadRealConfig()
    local printLog = {}
    local function printStub(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        printLog[#printLog + 1] = table.concat(parts, '\t')
    end
    local env = Sandbox.newEnv({ print = printStub })
    Sandbox.loadInto('../config.lua', env)
    return env, printLog
end

-- ========================================================================
-- 1 + 2 + 3 -- NO-OP ON DEFAULTS, NEVER SILENTLY RE-ENABLE, DRIFT GUARD
-- ========================================================================

t.test('SANITY: the real config.lua actually produced a real, non-empty Config.FeaturesBeforeGrouping (a load failure that silently produced an empty table would otherwise make every loop below pass vacuously)', function()
    local env = loadRealConfig()
    local count = 0
    for _ in pairs(env.Config.FeaturesBeforeGrouping) do count = count + 1 end
    t.isTrue(count >= 56, ('expected at least 56 keys in Config.FeaturesBeforeGrouping, saw %d'):format(count))
end)

t.test('NO-OP ON DEFAULTS: every single real Config.Features key resolves, under the REAL shipped Config.FeatureGroups, to EXACTLY its own pristine pre-grouping value -- the whole restructure is provably a no-op on defaults', function()
    local env = loadRealConfig()
    local mismatches = {}
    for key, beforeValue in pairs(env.Config.FeaturesBeforeGrouping) do
        if env.Config.Features[key] ~= beforeValue then
            mismatches[#mismatches + 1] = ('%s: before=%s after=%s'):format(key, tostring(beforeValue), tostring(env.Config.Features[key]))
        end
    end
    t.equals(#mismatches, 0, 'mismatches: ' .. table.concat(mismatches, '; '))
end)

t.test('NEVER SILENTLY RE-ENABLE: the three keys that ship false stay false after resolution -- DiscordWebhook, CertificationExpiry, DangerWarn (NOT BoneSweepDevTool, which this suite confirms below actually ships true; NOT HandlerXPProgression, which now deliberately ships true -- see the test immediately below)', function()
    local env = loadRealConfig()
    t.isFalse(env.Config.Features.DiscordWebhook)
    t.isFalse(env.Config.Features.CertificationExpiry)
    t.isFalse(env.Config.Features.DangerWarn)
end)

-- ============================================================================
-- HandlerXPProgression moved OUT of the ships-false pin above on 2026-08-27.
-- This is the deliberate, recorded flip that guard existed to prevent
-- happening SILENTLY -- so it is pinned just as hard in its new position,
-- and in BOTH of its places, because the two of them disagreeing is what
-- made this feature dead in the first place.
--
-- WHY IT FLIPPED: AwardHandlerXP (server/progression.lua) hard-returns on
-- Config.Features.HandlerXPProgression before doing anything, and it is the
-- only function anywhere that mints Handler XP. While the flag shipped
-- false, all six award keys fired, passed their cooldowns, called
-- AwardHandlerXP and minted exactly zero -- so the handler rank ladder was
-- not slow, it was dead, while the tablet advertised the ranks. The
-- anti-farm gap that originally justified the false is closed (both new
-- mints are per-actor, citizenid-keyed and survive disconnect/reconnect).
--
-- WHY BOTH KEYS ARE ASSERTED: group resolution runs AFTER Config.Features,
-- so Config.FeatureGroups.Progression.HandlerXP silently overrides the
-- Config.Features value. Flipping only Config.Features resolved true ->
-- false and changed nothing at all -- caught by the NO-OP ON DEFAULTS test
-- above, which is the only reason it was noticed. Pinning both directions
-- here means a future edit to either one alone fails a test instead of
-- quietly re-killing the ladder.
-- ============================================================================
t.test('DELIBERATE GO-LIVE, PINNED IN BOTH PLACES: HandlerXPProgression ships true AND its owning group key Config.FeatureGroups.Progression.HandlerXP ships true -- the two must agree, because the group key silently wins over Config.Features and a mismatch makes the whole handler rank ladder mint zero XP with no error anywhere', function()
    local env = loadRealConfig()
    t.isTrue(env.Config.Features.HandlerXPProgression)
    t.isTrue(env.Config.FeatureGroups.Progression.HandlerXP)
end)

t.test('CORRECTION ON RECORD: BoneSweepDevTool ships true (gated instead by a separate convar + ACE check, not by this flag) -- an earlier draft of this task\'s own brief named it as a ships-false example; this pins the real, corrected fact so it cannot silently drift back to the wrong claim', function()
    local env = loadRealConfig()
    t.isTrue(env.Config.Features.BoneSweepDevTool)
end)

t.test('REMOVED: ScentTrailHunt is genuinely absent from Config.Features (owner-approved removal, not merely folded) -- reads nil, which is what makes server/scenttrail.lua\'s own untouched top-level gate correctly inert', function()
    local env = loadRealConfig()
    t.isNil(env.Config.Features.ScentTrailHunt)
    t.isNil(env.Config.FeaturesBeforeGrouping.ScentTrailHunt)
end)

t.test('DRIFT GUARD: every real Config.Features key is accounted for by exactly one family (GetFeatureGroupFamily) or the standalone list (IsStandaloneFeatureFlag) -- this is the exact mechanism that would catch a new key (like HungerThirstSystem was, mid-session) landing with no home in this tree', function()
    local env = loadRealConfig()
    local unaccounted = {}
    for key in pairs(env.Config.FeaturesBeforeGrouping) do
        local family = env.GetFeatureGroupFamily(key)
        local standalone = env.IsStandaloneFeatureFlag(key)
        if not family and not standalone then
            unaccounted[#unaccounted + 1] = key
        end
        -- Also never BOTH -- a key claimed by a family AND the standalone
        -- list at once would be a real, silent contradiction (which value
        -- wins would depend on iteration order, which Lua does not
        -- guarantee) -- fail loudly rather than let that possibility exist
        -- unchecked.
        if family and standalone then
            unaccounted[#unaccounted + 1] = key .. ' (claimed by BOTH a family and the standalone list)'
        end
    end
    t.equals(#unaccounted, 0, 'unaccounted-for key(s): ' .. table.concat(unaccounted, ', '))
end)

t.test('DRIFT GUARD, THE OTHER DIRECTION: HungerThirstSystem specifically -- the real key that landed mid-session and proved this guard works -- is present and correctly homed under Wellbeing', function()
    local env = loadRealConfig()
    t.isNotNil(env.Config.FeaturesBeforeGrouping.HungerThirstSystem, 'HungerThirstSystem must exist in the real, shipped config.lua for this test to mean anything')
    t.equals(env.GetFeatureGroupFamily('HungerThirstSystem'), 'Wellbeing')
end)

-- ========================================================================
-- 5 -- SILENT ON THE NORMAL PATH
-- ========================================================================

t.test('SILENT ON THE NORMAL PATH: loading the real, valid, untouched config.lua prints absolutely nothing -- a valid config is completely silent at load, matching this resource\'s own broad contract', function()
    local env, printLog = loadRealConfig()
    t.equals(#printLog, 0, 'unexpected print(s): ' .. table.concat(printLog, ' | '))
    -- Referencing env so luacheck/static tools never flag it unused if this
    -- test is ever extended.
    t.isNotNil(env.Config)
end)

-- ========================================================================
-- OLD FLAT SHAPE -- byte-for-byte unchanged, one-time notice
-- ========================================================================

t.test('OLD FLAT SHAPE: with Config.FeatureGroups entirely absent, a custom flat value is left completely untouched by a re-resolve -- proves the old shape is a true no-op, never a guess', function()
    local env = loadRealConfig()
    env.Config.Features.BiteAndHold = false -- a real, deliberate operator customization in the OLD flat style
    env.Config.Features.DangerWarn = true   -- likewise -- an operator who explicitly opted a ships-false flag ON must never be overridden back
    env.Config.FeatureGroups = nil

    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.BiteAndHold, 'a customized OLD-shape value must never be touched when Config.FeatureGroups is absent')
    t.isTrue(env.Config.Features.DangerWarn, 'same -- including for a flag that ships false by default')
end)

t.test('OLD FLAT SHAPE: prints exactly one, actionable, one-time notice naming the classic format', function()
    local env, printLog = loadRealConfig()
    env.Config.FeatureGroups = nil
    for key in pairs(printLog) do printLog[key] = nil end

    env.ResolveFeatureGroups()

    t.equals(#printLog, 1, 'expected exactly one line: ' .. table.concat(printLog, ' | '))
    t.contains(printLog[1], 'Config.FeatureGroups not found')
    t.contains(printLog[1], 'classic flat format')
end)

-- ========================================================================
-- 4 -- PARENT OFF FORCES CHILDREN OFF
-- ========================================================================

t.test('PARENT OFF FORCES CHILDREN OFF: Config.FeatureGroups.Combat.enabled = false forces every Combat child false, even one explicitly set true in Config.FeatureGroups itself', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups.Combat.enabled = false
    env.Config.FeatureGroups.Combat.BiteAndHold = true -- explicit true, must still lose to the parent

    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.BiteAndHold)
    t.isFalse(env.Config.Features.NonLethalTakedown)
    t.isFalse(env.Config.Features.PropDragging)
    t.isFalse(env.Config.Features.PursuitSprint)
    t.isFalse(env.Config.Features.HandlerDownDefense)
    t.isFalse(env.Config.Features.DangerWarn) -- already false by default -- must STAY false, not somehow flip
end)

t.test('PARENT OFF FORCES CHILDREN OFF prints exactly which children it forced, naming the family -- the actionable warning this whole mechanism exists to surface', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Combat.enabled = false

    env.ResolveFeatureGroups()

    local found = nil
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Combat.enabled is false', 1, true) then found = line end
    end
    t.isNotNil(found, 'expected a forced-off warning naming Combat')
    t.contains(found, 'BiteAndHold')
    t.contains(found, 'NonLethalTakedown')
    t.contains(found, 'PropDragging')
    t.contains(found, 'PursuitSprint')
    t.contains(found, 'HandlerDownDefense')
    t.notContains(found, 'DangerWarn', 'DangerWarn was already false by default -- it was never FORCED off, so it must not be named as if it were')
end)

t.test('PARENT ON, NO FORCED-OFF PRINT: flipping Combat.enabled back to true (its own default) after having been false prints nothing new and fully recovers every child\'s TRUE original default -- the idempotency guarantee this resolver\'s own doc comment makes', function()
    local env, printLog = loadRealConfig()
    env.Config.FeatureGroups.Combat.enabled = false
    env.ResolveFeatureGroups()
    t.isFalse(env.Config.Features.BiteAndHold)

    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Combat.enabled = true
    env.ResolveFeatureGroups()

    t.equals(#printLog, 0, 'flipping back to the default must be silent: ' .. table.concat(printLog, ' | '))
    t.isTrue(env.Config.Features.BiteAndHold, 'must recover the TRUE original default -- reading Config.Features\' own already-narrowed value here instead of the pristine snapshot would have left this stuck false forever')
    t.isTrue(env.Config.Features.NonLethalTakedown)
    t.isTrue(env.Config.Features.PropDragging)
    t.isFalse(env.Config.Features.DangerWarn, 'DangerWarn\'s own real default is false -- recovering the ORIGINAL default must not be confused with recovering "true"')
end)

t.test('IDEMPOTENCY, THE CASE THAT ACTUALLY EXERCISES THE FALLBACK PATH: an operator who OMITS a child from Config.FeatureGroups entirely (never sets Combat.BiteAndHold at all, unlike the shipped default template which spells out every child explicitly) still recovers its TRUE original shipped value after a disable-then-reenable cycle -- this is the one shape that would have caught this resolver reading its own already-narrowed Config.Features value as if it were the pristine default, since the shipped defaults alone (every child spelled out explicitly) never exercise the omitted-child fallback branch at all', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups.Combat.BiteAndHold = nil -- OMITTED, not merely set to true -- this is the load-bearing difference from the shipped template

    env.Config.FeatureGroups.Combat.enabled = false
    env.ResolveFeatureGroups()
    t.isFalse(env.Config.Features.BiteAndHold, 'sanity: parent-off still forces the omitted child off too')

    env.Config.FeatureGroups.Combat.enabled = true
    env.ResolveFeatureGroups()
    t.isTrue(env.Config.Features.BiteAndHold, 'must recover true (the pristine original shipped default) -- a resolver reading its own live, already-narrowed Config.Features value here instead would find `false` with nothing left to recover the real default from, and this would fail')
end)

t.test('BASE COLLAPSE: Detection.enabled directly IS the resolved ScentTracking value -- toggling one toggles the other, with no separate child slot for it', function()
    local env = loadRealConfig()
    t.isTrue(env.Config.Features.ScentTracking) -- sanity: shipped default

    env.Config.FeatureGroups.Detection.enabled = false
    env.ResolveFeatureGroups()
    t.isFalse(env.Config.Features.ScentTracking)
    t.isFalse(env.Config.Features.BloodTracking, 'a Detection child with no override in Config.FeatureGroups must also be forced off by the parent')
end)

t.test('STANDALONE FLAGS ARE NEVER GATED BY ANY FAMILY: Recall stays true even while Combat (its former display grouping\'s sibling, and the very capability it is the escape hatch for) is entirely disabled', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups.Combat.enabled = false
    env.Config.FeatureGroups.Movement.enabled = false -- Recall's own former, wrong, display grouping

    env.ResolveFeatureGroups()

    t.isTrue(env.Config.Features.Recall, 'Recall must never be forced off by ANY family switch -- see FEATURE_STRUCTURE_SPEC.md §3.2')
    t.isFalse(env.Config.Features.BiteAndHold) -- sanity: Combat really is off
    t.isFalse(env.Config.Features.LeashMechanics) -- sanity: Movement really is off
end)

t.test('STANDALONE FLAGS: an explicit standalone override is applied directly, with no parent to consult at all', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups.HighCommand = false

    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.HighCommand)
end)

-- ========================================================================
-- IsFeatureGroupParentEnabled -- the accessor server/runtimecontrol.lua's
-- own live-override refusal and boot-reapply skip both depend on
-- ========================================================================

t.test('IsFeatureGroupParentEnabled: false for a child whose family is disabled, true for the same child once re-enabled', function()
    local env = loadRealConfig()
    t.isTrue(env.IsFeatureGroupParentEnabled('BiteAndHold'), 'sanity: enabled by default')

    env.Config.FeatureGroups.Combat.enabled = false
    t.isFalse(env.IsFeatureGroupParentEnabled('BiteAndHold'))

    env.Config.FeatureGroups.Combat.enabled = true
    t.isTrue(env.IsFeatureGroupParentEnabled('BiteAndHold'))
end)

t.test('IsFeatureGroupParentEnabled: always true for a standalone flag, regardless of any family\'s state -- there is no parent to be blocked by', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups.Combat.enabled = false
    env.Config.FeatureGroups.Movement.enabled = false

    t.isTrue(env.IsFeatureGroupParentEnabled('Recall'))
    t.isTrue(env.IsFeatureGroupParentEnabled('HighCommand'))
end)

t.test('IsFeatureGroupParentEnabled: always true when Config.FeatureGroups is entirely absent (old flat shape) -- there is no parent concept to consult at all', function()
    local env = loadRealConfig()
    env.Config.FeatureGroups = nil

    t.isTrue(env.IsFeatureGroupParentEnabled('BiteAndHold'))
end)

t.test('IsFeatureGroupParentEnabled: always true for a genuinely unrecognized name -- fails open on "nothing to be blocked by", never errors', function()
    local env = loadRealConfig()
    t.isTrue(env.IsFeatureGroupParentEnabled('SomeFeatureThatDoesNotExist'))
end)

-- ========================================================================
-- CLAMP AND WARN, NEVER ASSERT
-- ========================================================================

t.test('CLAMP AND WARN: a non-table family is ignored, warns naming the exact family, and every member keeps its pristine original value -- never an error, never a crash', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Combat = 'not a table'

    local ok = pcall(env.ResolveFeatureGroups)
    t.isTrue(ok, 'must never throw')

    t.isTrue(env.Config.Features.BiteAndHold, 'members of a malformed family must keep their pristine original value')
    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Combat is not a table', 1, true) then warned = true end
    end
    t.isTrue(warned)
end)

t.test('CLAMP AND WARN: a non-boolean enabled is treated as true and warns naming the exact field', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Movement.enabled = 'yes'

    env.ResolveFeatureGroups()

    t.isTrue(env.Config.Features.LeashMechanics, 'a malformed enabled must clamp to true, the safe default')
    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Movement.enabled is not a boolean', 1, true) then warned = true end
    end
    t.isTrue(warned)
end)

t.test('CLAMP AND WARN: a non-boolean child value is ignored, warns naming the exact field, and that one child falls back to its pristine original value -- siblings are unaffected', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Detection.Blood = 'not-a-boolean'

    env.ResolveFeatureGroups()

    t.isTrue(env.Config.Features.BloodTracking, 'must fall back to the pristine original shipped value, not silently become false')
    t.isTrue(env.Config.Features.ScentTracking, 'an unrelated sibling in the same family must be entirely unaffected')
    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.Detection.Blood is not a boolean', 1, true) then warned = true end
    end
    t.isTrue(warned)
end)

t.test('CLAMP AND WARN: a non-boolean standalone override is ignored, warns, and the flag keeps its current value -- never an error', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.HighCommand = 'nope'

    local ok = pcall(env.ResolveFeatureGroups)
    t.isTrue(ok, 'must never throw')

    t.isTrue(env.Config.Features.HighCommand, 'must keep its existing value, not silently become false/nil')
    local warned = false
    for _, line in ipairs(printLog) do
        if line:find('Config.FeatureGroups.HighCommand is not a boolean', 1, true) then warned = true end
    end
    t.isTrue(warned)
end)

t.test('CLAMP AND WARN: a family simply omitted from Config.FeatureGroups entirely is silent -- an operator sparsely editing only ONE family must never be warned about every OTHER family they left untouched', function()
    local env, printLog = loadRealConfig()
    env.Config.FeatureGroups.Wellbeing = nil
    for key in pairs(printLog) do printLog[key] = nil end

    env.ResolveFeatureGroups()

    t.equals(#printLog, 0, 'omitting a family entirely is not malformed input: ' .. table.concat(printLog, ' | '))
    t.isTrue(env.Config.Features.FatigueSystem, 'an omitted family must behave as fully enabled with no overrides -- i.e. unchanged from its shipped default')
end)

-- ========================================================================
-- FLAT/GROUPED DISAGREEMENT -- the gap this task's own brief describes:
-- a family's own `enabled` stays true (so `forcedOff` above has nothing to
-- say) while its flat Config.Features value and its Config.FeatureGroups
-- counterpart simply disagree -- today that resolves silently to the
-- grouped value, with no console line at all. This is the exact shape that
-- made a `true` in Config.Features.HandlerXPProgression silently resolve
-- back to `false` for real, once (see that key's own header comment in
-- config.lua). These tests cover all three places a flat/grouped pair can
-- live: an ordinary family child, a family's `enabled` (the base flag's own
-- grouped counterpart), and a standalone flag.
--
-- Every scenario below is built by mutating a FRESH sandboxed copy of the
-- real config.lua (see loadRealConfig, and the existing OLD FLAT SHAPE
-- tests above using this exact same technique) -- never the real, shipped
-- config.lua on disk, and never a value this task was told not to change.
-- ========================================================================

t.test('FLAT/GROUPED DISAGREEMENT: an ordinary family child that explicitly disagrees with the flat pristine default is reported by name, even while the family itself stays enabled -- the exact silent-override bug shape (HandlerXPProgression, 2026-08-27) this diagnostic exists to catch', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Progression.HandlerXP = false -- disagrees with the real shipped Config.Features.HandlerXPProgression, which is true

    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.HandlerXPProgression, 'sanity: unchanged existing behaviour -- the grouped value still silently wins')
    local found = nil
    for _, line in ipairs(printLog) do
        if line:find('HandlerXPProgression', 1, true) and line:find('disagree', 1, true) then found = line end
    end
    t.isNotNil(found, 'expected a disagreement warning naming HandlerXPProgression: ' .. table.concat(printLog, ' | '))
    t.contains(found, 'Config.Features.HandlerXPProgression')
    t.contains(found, 'Config.FeatureGroups.Progression.HandlerXP')
    t.contains(found, 'ON')
    t.contains(found, 'OFF')
end)

t.test('FLAT/GROUPED DISAGREEMENT CONTROL: an explicit override that AGREES with the flat pristine default prints nothing new -- proves this diagnostic fires on a genuine mismatch only, not on every explicit override (which would make 60 lines of noise at every boot and train everyone to ignore this console)', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Progression.HandlerXP = true -- already the real shipped value -- explicit, but not a disagreement

    env.ResolveFeatureGroups()

    t.equals(#printLog, 0, 'an explicit override that matches the flat default must stay silent: ' .. table.concat(printLog, ' | '))
end)

t.test('FLAT/GROUPED DISAGREEMENT: a family\'s "enabled" (the grouped counterpart of its own base flag, e.g. Detection.enabled for ScentTracking) silently overriding a differing flat default is reported too, not just an ordinary child override -- simulates a fresh boot where the operator edited Config.Features.ScentTracking directly and never touched Config.FeatureGroups.Detection.enabled', function()
    local env, printLog = loadRealConfig()
    env.Config.Features.ScentTracking = false     -- what the operator wrote in the flat block
    env.Config.FeaturesBeforeGrouping = nil        -- re-arm the "first call ever" snapshot so THIS becomes what gets captured as the pristine flat value -- simulating a genuinely fresh boot with this authored value, never touching the real shipped config.lua
    for key in pairs(printLog) do printLog[key] = nil end

    env.ResolveFeatureGroups()

    t.isTrue(env.Config.Features.ScentTracking, 'sanity: Detection.enabled (left at its own shipped true) still silently wins -- unchanged existing behaviour, exactly the reported bug shape')
    local found = nil
    for _, line in ipairs(printLog) do
        if line:find('ScentTracking', 1, true) and line:find('disagree', 1, true) then found = line end
    end
    t.isNotNil(found, 'expected a disagreement warning naming ScentTracking: ' .. table.concat(printLog, ' | '))
    t.contains(found, 'Config.Features.ScentTracking')
    t.contains(found, 'Config.FeatureGroups.Detection.enabled')
end)

t.test('FLAT/GROUPED DISAGREEMENT: a standalone flag disagreement is reported too, not just family members', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.HighCommand = false -- disagrees with the real shipped Config.Features.HighCommand, which is true

    env.ResolveFeatureGroups()

    t.isFalse(env.Config.Features.HighCommand, 'sanity: unchanged existing behaviour -- the grouped value still silently wins')
    local found = nil
    for _, line in ipairs(printLog) do
        if line:find('HighCommand', 1, true) and line:find('disagree', 1, true) then found = line end
    end
    t.isNotNil(found, 'expected a disagreement warning naming HighCommand: ' .. table.concat(printLog, ' | '))
    t.contains(found, 'Config.Features.HighCommand')
    t.contains(found, 'Config.FeatureGroups.HighCommand')
end)

t.test('FLAT/GROUPED DISAGREEMENT IS SUPPRESSED WHILE THE FAMILY ITSELF IS DISABLED: an explicit child override that disagrees with the flat default must print ONLY the existing forced-off warning while Config.FeatureGroups.Combat.enabled is false, never an additional disagreement line -- the parent-off case already has its own, clearer message, and printing both would be confusing, not helpful', function()
    local env, printLog = loadRealConfig()
    for key in pairs(printLog) do printLog[key] = nil end
    env.Config.FeatureGroups.Combat.enabled = false
    env.Config.FeatureGroups.Combat.BiteAndHold = false -- explicit, and disagrees with the real shipped flat default (true) -- must still not print a disagreement line, only forcedOff logic (which does not even apply here since it's already false)

    env.ResolveFeatureGroups()

    for _, line in ipairs(printLog) do
        t.isTrue(not line:find('disagree', 1, true), 'no disagreement line expected while the family is disabled: ' .. line)
    end
end)

print('')
os.exit(t.summary())
