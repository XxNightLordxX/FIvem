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
    skipping it -- see tests/README.md's coverage table.
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
function Sandbox.newEnv(overrides)
    local env = {}
    for key, value in pairs(_G) do
        env[key] = value
    end
    env._G = env
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
