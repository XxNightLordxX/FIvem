--[[
    tests/fixtures/sandbox.lua

    Loads a REAL, unmodified server/*.lua source file into an isolated Lua
    environment table so its pure logic can be exercised outside the FXServer
    runtime, without ever touching the real global table (_G) and without
    editing the production file.

    HOW THIS WORKS: Lua 5.2+ compiles every global read/write in a chunk
    through the `_ENV` upvalue. `load(chunk, name, mode, env)` lets a caller
    supply that upvalue directly, so a production file's own
    `function NewCooldown() ... end` (an implicit-global assignment) writes
    into OUR `env` table, not the process's real global table -- callable
    afterwards as `env.NewCooldown(...)`, with zero modification to the
    source file itself.

    WHAT THIS DOES NOT SOLVE: a `local function Foo()` in the production file
    is still only reachable from code inside that same file (this resource's
    own convention -- see server/cooldowns.lua's header on the
    global-helper-vs-local-file-state split). Where a spec needs to exercise
    logic gated behind a `local`, it does so the same way a real caller
    would: by invoking whatever resource-global entry point (a captured
    RegisterCommand handler, AddEventHandler callback, or exposed accessor
    like GetXPTier) the production file itself already wires that local
    function into, and asserting on the observable result. Where a local is
    not reachable that way at all without disproportionate native stubbing,
    the corresponding spec file says so in a comment rather than silently
    skipping it -- see DEVELOPER_REFERENCE.md's coverage table.
]]

local Sandbox = {}

--- Builds a fresh sandbox environment table: a shallow copy of the real
--- `_G` (so standard library calls -- string/table/math/pairs/ipairs/pcall/
--- tostring/tonumber/assert/error/print/... -- all work exactly as normal
--- inside a loaded chunk), with `overrides` layered on top (FiveM/CFX native
--- stubs, `Config`, etc.). `env._G` is pointed at `env` itself (not the real
--- `_G`) so a production file's own explicit `_G.Something(...)` call (e.g.
--- server/admin.lua's NotifyPlayer wrapper) resolves against the sandbox,
--- not the real process globals.
--- @param overrides table<string, any>
--- @return table env
--- Minimal JSON reader, sufficient for `locales/*.json`: nested objects
--- whose leaves are all strings. Deliberately NOT a general JSON parser --
--- it rejects anything outside that shape loudly rather than guessing, so a
--- locale file that grows arrays or numbers fails the suite instead of
--- silently half-loading.
local function parseJsonObject(text, pos)
    local out = {}
    pos = text:find('%S', pos)
    assert(text:sub(pos, pos) == '{', 'expected { at ' .. pos)
    pos = pos + 1
    while true do
        pos = text:find('%S', pos)
        assert(pos, 'unterminated object')
        local char = text:sub(pos, pos)
        if char == '}' then return out, pos + 1 end
        if char == ',' then
            pos = pos + 1
        else
            assert(char == '"', 'expected key string at ' .. pos)
            local keyStart = pos
            local key
            key, pos = text:match('^"([^"\\]*)"()', pos)
            assert(key, 'unsupported escape in object key at ' .. keyStart)
            pos = text:find('%S', pos)
            assert(text:sub(pos, pos) == ':', 'expected : after key ' .. key)
            pos = text:find('%S', pos + 1)
            if text:sub(pos, pos) == '{' then
                out[key], pos = parseJsonObject(text, pos)
            else
                assert(text:sub(pos, pos) == '"', 'locale leaves must be strings; got non-string for ' .. key)
                -- Consume a JSON string with escapes, one char at a time.
                local buf, index = {}, pos + 1
                while true do
                    local c = text:sub(index, index)
                    assert(c ~= '', 'unterminated string for ' .. key)
                    if c == '\\' then
                        local nextChar = text:sub(index + 1, index + 1)
                        local simple = ({ n = '\n', t = '\t', r = '\r', b = '\b', f = '\f',
                                          ['"'] = '"', ['\\'] = '\\', ['/'] = '/' })[nextChar]
                        assert(simple, 'unsupported escape \\' .. nextChar .. ' in ' .. key)
                        buf[#buf + 1] = simple
                        index = index + 2
                    elseif c == '"' then
                        index = index + 1
                        break
                    else
                        buf[#buf + 1] = c
                        index = index + 1
                    end
                end
                out[key] = table.concat(buf)
                pos = index
            end
        end
    end
end

--- Loads `../locales/en.json` once (specs run with cwd = tests/, the same
--- convention every `Sandbox.loadInto('../server/...')` call already uses) and returns an ox_lib-shaped `locale()`.
--- Unlike ox_lib (which returns the key itself when a key is missing, so a
--- missing key shows up only as odd text in-game), this DELIBERATELY raises.
--- Every spec that exercises a code path through a `locale()` call therefore
--- doubles as a check that the key really exists in `en.json` -- the exact
--- failure a live server-side migration pass shipped once already.
local localeDict
function Sandbox.locale(key, ...)
    if not localeDict then
        local handle = assert(io.open('../locales/en.json', 'r'))
        local text = handle:read('a')
        handle:close()
        localeDict = (parseJsonObject(text, 1))
    end
    local group, leaf = key:match('^([^.]+)%.(.+)$')
    local value = group and localeDict[group] and localeDict[group][leaf] or localeDict[key]
    assert(type(value) == 'string', "locale key missing from locales/en.json: " .. tostring(key))
    if select('#', ...) > 0 then return value:format(...) end
    return value
end

--- vector2/vector3/vector4 are NOT natives and have no decl page to check.
--- They are Lua RUNTIME TYPES that CitizenFX's Lua build adds to the
--- language itself, in both realms, so a production file may use them at
--- file-load time -- config.lua does, for Config.K9EquipmentShop.locations,
--- because ox_target's addSphereZone takes a vector3 for `coords`. Plain
--- lua5.4 has no such constructor, so without these the sandbox raises
--- "attempt to call a nil value (global 'vector3')" and every spec that
--- loads the real config.lua fails at once -- which is exactly what
--- happened when that config landed, taking 14 spec files red in one go.
---
--- These are DELIBERATELY minimal: a table carrying x/y/z(/w) and nothing
--- else. They model the fields production code reads, not CitizenFX's real
--- vector arithmetic. If a production file ever starts doing MATH on one of
--- these (v1 - v2, #v, v * 2), this stub will not catch the bug, and the
--- right move then is to give it real metamethods rather than to widen a
--- test around it. Recorded so nobody mistakes silence here for coverage.
local function makeVector(fields)
    return function(...)
        local v, args = {}, { ... }
        for i, name in ipairs(fields) do v[name] = args[i] end
        return v
    end
end

Sandbox.vector2 = makeVector({ 'x', 'y' })
Sandbox.vector3 = makeVector({ 'x', 'y', 'z' })
Sandbox.vector4 = makeVector({ 'x', 'y', 'z', 'w' })

function Sandbox.newEnv(overrides)
    local env = {}
    for key, value in pairs(_G) do
        env[key] = value
    end
    env._G = env
    env.locale = Sandbox.locale
    env.vector3 = Sandbox.vector3
    env.vector2 = Sandbox.vector2
    env.vector4 = Sandbox.vector4
    for key, value in pairs(overrides or {}) do
        env[key] = value
    end
    return env
end

--- Loads and immediately executes `path` inside `env`. Any top-level
--- `function Foo() ... end` / `Foo = ...` in the source file becomes
--- `env.Foo`. Any `AddEventHandler`/`RegisterCommand`/etc. call the file
--- makes at load time is whatever `env` provides for that name (a capturing
--- stub, per this fixture's callers).
--- @param path string -- real path to a production .lua file, never modified
--- @param env table -- from Sandbox.newEnv
function Sandbox.loadInto(path, env)
    local chunk, err = loadfile(path, 't', env)
    if not chunk then
        error(('sandbox: failed to load %s: %s'):format(path, tostring(err)))
    end
    chunk()
end

--- Builds a minimal, cooperative CreateThread/Wait pair backed by Lua
--- coroutines, for specs that need to step through a `while true do
--- Wait(x) ... end` sweep-thread body one pass at a time without it looping
--- forever synchronously (Wait is stubbed to yield instead of sleeping).
---
--- NOTE on stepping semantics: because every sweep thread in this resource
--- calls Wait(...) as its FIRST statement inside the loop, the FIRST
--- runner.step() call only reaches that initial Wait and yields immediately
--- -- it primes the coroutine but performs no sweep pass. Each call after
--- that runs exactly one full loop body (one sweep pass) before yielding at
--- the next Wait(...). Callers that want "one pass" should call step()
--- twice: once to prime, once to execute.
--- @return table runner -- { CreateThread = fun, Wait = fun, step = fun }
function Sandbox.newThreadRunner()
    local threads = {}
    local runner = {}

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(_ms)
        coroutine.yield()
    end

    --- Resumes every still-alive captured thread once.
    function runner.step()
        for _, co in ipairs(threads) do
            if coroutine.status(co) ~= 'dead' then
                local ok, errOrNil = coroutine.resume(co)
                if not ok then
                    error(('sandbox thread runner: captured thread errored: %s'):format(tostring(errOrNil)))
                end
            end
        end
    end

    return runner
end

return Sandbox
