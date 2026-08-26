--[[
    tests/tabletlocalization_spec.lua

    Regression coverage for the tablet localization pass: html/tablet.js's
    own DEFAULT_STRINGS (the English fallback / resilience net, KEPT
    unchanged) must stay a 1:1 KEY match with locales/en.json's `tablet`
    group, and client/tablet.lua's real OpenTablet() payload must actually
    send every one of those keys, locale()-resolved, not the old `{}`.

    This file does NOT re-derive DEFAULT_STRINGS' VALUES from JS (a real
    JS parser is out of scope for a zero-dependency Lua spec) -- it extracts
    just the KEY NAMES with a narrow, line-oriented pattern identical in
    spirit to the one used to originally enumerate them (`^%s+([%a_][%w_]*):%s*'`),
    which is exactly precise enough to catch the one thing that actually
    matters here: a key added to/removed from html/tablet.js's
    DEFAULT_STRINGS without a matching change in locales/en.json's `tablet`
    group and client/tablet.lua's TABLET_STRING_KEYS list. VALUE correctness
    (byte-for-byte against DEFAULT_STRINGS) was verified by hand against a
    real JS-object parse when these three files were authored; this spec
    guards the key SET from silently drifting apart afterward.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local locale = Sandbox.locale

-- ----------------------------------------------------------------------
-- Extract DEFAULT_STRINGS' key names straight from the real,
-- unmodified html/tablet.js.
-- ----------------------------------------------------------------------

--- @return string[] keys, integer count
local function ExtractDefaultStringsKeys()
    local handle = assert(io.open('../html/tablet.js', 'r'))
    local text = handle:read('a')
    handle:close()

    local startPos = text:find('var DEFAULT_STRINGS = {', 1, true)
    assert(startPos, 'DEFAULT_STRINGS declaration not found in html/tablet.js')
    local endPos = text:find('\n    };', startPos, true)
    assert(endPos, 'closing "};" for DEFAULT_STRINGS not found')
    local body = text:sub(startPos, endPos)

    local keys = {}
    for line in body:gmatch('[^\n]+') do
        local key = line:match("^%s+([%a_][%w_]*):%s*'")
        if key then keys[#keys + 1] = key end
    end
    return keys, #keys
end

-- ----------------------------------------------------------------------
-- Minimal fixture -- just enough of client/tablet.lua's own load-time
-- dependencies to reach OpenTablet()'s tablet:open payload. Full
-- behavioral coverage (focus lifecycle, NUI callbacks, SECTION 2/3, etc.)
-- already lives in tests/clienttablet_spec.lua; this fixture only needs to
-- prove the `strings` payload.
-- ----------------------------------------------------------------------

local function newFixture()
    local sendNuiMessageCalls = {}
    local function SendNUIMessage(payload) sendNuiMessageCalls[#sendNuiMessageCalls + 1] = payload end
    local function SetNuiFocus(_hasFocus, _hasCursor) end

    local runner = Sandbox.newThreadRunner()
    local function CreateThread(fn) runner.CreateThread(fn) end
    local function Wait(ms) runner.Wait(ms) end

    local function RegisterCommand(_name, _handler, _restricted) end
    local function RegisterNUICallback(_name, _handler) end
    local function AddEventHandler(_eventName, _handler) end
    local function GetCurrentResourceName() return 'qbx_k9unit' end
    local function GetResourceState(_resourceName) return 'started' end
    local function DisableControlAction() end
    local function IsDisabledControlJustPressed() return false end
    local function IsEntityDead() return false end
    local function PlayerPedId() return 1 end

    local fakeK9Compat = {
        Which = function() return nil end, -- no inventory adapter needed for this spec
        Get = function() return {} end,
    }

    local overrides = {
        SendNUIMessage = SendNUIMessage, SetNuiFocus = SetNuiFocus,
        CreateThread = CreateThread, Wait = Wait,
        RegisterCommand = RegisterCommand, RegisterNUICallback = RegisterNUICallback,
        AddEventHandler = AddEventHandler, GetCurrentResourceName = GetCurrentResourceName,
        GetResourceState = GetResourceState, K9Compat = fakeK9Compat,
        DisableControlAction = DisableControlAction,
        IsDisabledControlJustPressed = IsDisabledControlJustPressed,
        IsEntityDead = IsEntityDead, PlayerPedId = PlayerPedId,
        lib = { notify = function() end, callback = { await = function() error('not needed for this spec', 0) end } },
        CanShowK9UI = function() return true end,
        HasK9Access = function() return true end,
        DenyK9UIAccess = function() end,
    }

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)

    env.Config.Features.CommandTablet = true
    env.Config.CommandTablet = env.Config.CommandTablet or {}
    env.Config.CommandTablet.openMode = 'command'
    env.Config.CommandTablet.command = 'k9tablet'
    env.Config.FeatureControl = env.Config.FeatureControl or {}
    env.Config.FeatureControl.allowActionsFromTablet = true

    Sandbox.loadInto('../client/tablet.lua', env)

    return {
        env = env,
        sendNuiMessageCalls = sendNuiMessageCalls,
    }
end

-- ----------------------------------------------------------------------
-- The key set itself: html/tablet.js's DEFAULT_STRINGS <-> locales/en.json
-- ----------------------------------------------------------------------

t.test('html/tablet.js DEFAULT_STRINGS has exactly 202 keys (the real, counted total -- not an approximation)', function()
    local _, count = ExtractDefaultStringsKeys()
    t.equals(count, 202)
end)

t.test('every DEFAULT_STRINGS key resolves via locale() against locales/en.json\'s `tablet` group', function()
    local keys = ExtractDefaultStringsKeys()
    for _, key in ipairs(keys) do
        local ok, result = pcall(locale, 'tablet.' .. key)
        t.isTrue(ok, 'locale(\'tablet.' .. key .. '\') should resolve, got error: ' .. tostring(result))
    end
end)

t.test('no duplicate keys in DEFAULT_STRINGS (a copy/paste key collision would silently drop a string)', function()
    local keys = ExtractDefaultStringsKeys()
    local seen = {}
    for _, key in ipairs(keys) do
        t.isNil(seen[key], 'duplicate DEFAULT_STRINGS key: ' .. key)
        seen[key] = true
    end
end)

-- ----------------------------------------------------------------------
-- The real production payload -- OpenTablet() must actually SEND every
-- one of those keys, locale()-resolved, not the old `strings = {}`.
-- ----------------------------------------------------------------------

t.test('OpenTablet(): `strings` is no longer the empty-table placeholder', function()
    local f = newFixture()
    f.env.OpenTablet()
    local msg = f.sendNuiMessageCalls[1]
    t.equals(msg.action, 'tablet:open')
    t.isTrue(next(msg.data.strings) ~= nil, 'strings must not ship empty')
end)

t.test('OpenTablet(): `strings` carries every DEFAULT_STRINGS key, each equal to locale(\'tablet.<key>\')', function()
    local f = newFixture()
    f.env.OpenTablet()
    local strings = f.sendNuiMessageCalls[1].data.strings

    local keys = ExtractDefaultStringsKeys()
    t.equals(#keys, 202)
    for _, key in ipairs(keys) do
        t.equals(strings[key], locale('tablet.' .. key), 'strings.' .. key .. ' must equal locale(\'tablet.' .. key .. '\')')
    end
end)

t.test('OpenTablet(): `strings` carries no MORE than 202 keys (no accidental extra/renamed entry going stale)', function()
    local f = newFixture()
    f.env.OpenTablet()
    local strings = f.sendNuiMessageCalls[1].data.strings

    local sentCount = 0
    for _ in pairs(strings) do sentCount = sentCount + 1 end
    t.equals(sentCount, 202)
end)

os.exit(t.summary())
