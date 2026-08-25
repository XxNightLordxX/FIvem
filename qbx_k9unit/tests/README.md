# qbx_k9unit automated tests

This directory is the first automated test suite for this resource. Before
this, the entire safety net was `luac5.4 -p` (syntax) and `luacheck`
(unused/undefined globals) — neither can catch a logic bug. Every logic bug
found in the QA passes that led to this suite (XP farms, a remote-steal, a
registry desync, a hesitation lockout) would have been caught by a test like
the ones here.

## Running

```sh
cd qbx_k9unit/tests
./run.sh
```

Requires `lua5.4` on `PATH` (the same runtime this resource ships against —
see `.github/workflows/lua-check.yml`, which already installs it for the
`luac5.4 -p` job). No other dependency. Set `LUA_BIN` to override the
interpreter path/name.

## Why plain lua5.4 + a tiny runner, not busted

`busted` is installed in this environment, but only for **Lua 5.1**
(`luarocks list` shows it under `rocks-5.1`; `lua5.1`/`luac5.1` are not on
`PATH` at all here, and this resource's own `.luacheckrc` pins
`std = "lua54"` to match the real FXServer runtime). Installing a
Lua-5.4-compatible busted was not possible in this sandbox (no working
outbound luarocks install path was available for a second Lua version), and
a test suite that only runs under a Lua version this resource doesn't
actually target would be worse than not having one — it could pass while
silently exercising different numeric/string semantics than the real
runtime (this mattered concretely: see `admin_spec.lua`'s `ClampLimit`
nan/inf tests, whose expected results depend on this exact Lua build's
`tonumber` behavior).

So: **zero dependencies, runs directly against the same `lua5.4` binary
FXServer embeds.** `testkit.lua` is ~100 lines — `test(name, fn)` runs `fn`
in its own `pcall` (one failing assertion fails only that test), a handful
of `equals`/`isTrue`/`isNil`/`contains`/... assertions that `error()` with a
readable message, and `summary()` prints a tally and returns an exit code.
Every `*_spec.lua` file is a self-contained script that `dofile`s
`testkit.lua`, runs its tests, and `os.exit()`s 0/1; `run.sh` just runs each
one and aggregates the exit codes.

## How production code gets under test without a FiveM runtime

FiveM natives (`GetGameTimer`, `TriggerClientEvent`, `MySQL.*`,
`exports.*`, ...) don't exist under plain `lua5.4`. `fixtures/sandbox.lua`
loads a **real, unmodified** `server/*.lua` file with `load(chunk, name,
't', env)`, where `env` is a table pre-populated with the small set of
native/global stubs that specific file actually needs (built as a shallow
copy of the real `_G`, so the standard library still works normally, plus
whatever's overridden). Because Lua 5.2+ compiles every global read/write
through the `_ENV` upvalue, this works with **zero changes to the
production file**: a top-level `function NewCooldown() end` in
`server/cooldowns.lua` becomes `env.NewCooldown`, callable from the test.

This gets you the REAL production logic under test, not a reimplementation
of it — the thing this task explicitly asked to avoid duplicating.

**What this cannot do anything about:** a `local function` in a production
file is only reachable from code in that same file, same as it would be
from a real caller. Every spec below reaches such a local the same way a
real caller does — through whatever resource-global entry point
(`RegisterCommand` handler, `AddEventHandler` callback, exported accessor)
the production file itself already wires it into — never by copying the
local's logic into the test. Where no such entry point exists without
disproportionate native stubbing, that's recorded as a coverage gap below,
not silently worked around.

## What's covered

| File | What's tested | How reached |
|---|---|---|
| `server/cooldowns.lua` | `NewCooldown`, `NewNestedCooldown`, `NewMutex` — check/stamp/consume/clear, the fail-closed behavior on a missing/zero/negative threshold, `RegisterPlayerDropped` per-source/per-primaryKey cleanup, `StartSweep`'s eviction predicate | Directly — all three are resource-globals (no `local`) |
| `server/admin.lua` | `ClampLimit` (the flagged nan/inf/1e400/float/negative battery — see below), `IsValidCitizenId`, `NormalizePlateArg`, `IsAuthorizedAdmin` (ACE grant/deny, console `TrustConsole` on/off, auth-checked-before-argument-shape), the shared `AuditCooldown` rate limit, `MergeSortedByIdDesc`, and (in `notify_spec.lua`) the local `NotifyPlayer` wrapper's `_G.NotifyPlayer(...)`-delegation to the real `server/notify.lua` | Indirectly, via the real `RegisterCommand` handlers captured after firing `onResourceStart`, asserting on the real SQL text / query params / notification content the real code produces |
| `server/progression.lua` | `ResolveTier` boundary resolution against `Config.XPTiers` (`>=` at a threshold vs. one below it, multi-step accumulation, top-tier resolution), the uncached-citizenid base-tier fail-safe, `AwardXP`'s unknown-actionKey/malformed-citizenid/feature-flag guards, the per-`(citizenid, actionKey)` rate floor, `CopyTier`'s defensive copy on the outbound tier-crossing event, the `playerDropped` cache-eviction fix | Indirectly, via the real `AwardXP`/`GetXPTier`/`GetXP` resource-globals |
| `server/entities.lua` | `ResolveNetworkEntity`'s full documented contract: non-number `netId` rejection, the `entity == 0 OR NOT DoesEntityExist` existence guard (including a stale-handle case), `expectedEntityType` match/omit/mismatch (mismatch is a hard `nil`, never advisory), and the documented "float/negative/huge netId fails via the existence check, not the type check" edge cases; `ResolveConnectedPlayerFromPed`'s scan-and-match, no-match, and malformed-`GetPlayers()`-entry cases | Directly — both are resource-globals (no `local`) |
| `server/notify.lua` | `NotifyPlayer`'s arity (2/3/4-arg calls, explicit-`nil` positional args, title-only override, no state leak between sequential calls) against the real `TriggerClientEvent('ox_lib:notify', ...)` call; the `_G.`-delegating local shadows in `server/admin.lua` and `server/bonetool.lua` (each file's own distinct title reaches the real notify event with no infinite recursion) | Directly for the shared function; indirectly for the two local wrappers, via each file's real `RegisterCommand` handler with the real `server/notify.lua` loaded into the same sandbox (not stubbed) |
| `server/tenure.lua` | `CheckTenureMilestonesForK9`/`TickPartnershipTenure`'s tier-boundary resolution (`>=` at `afterSeconds` vs. one second below), multi-milestone catch-up in a single tick, the persisted `tenure_bonus_tier_granted` column's optimistic-concurrency guard actually preventing a double grant (including across a simulated restart, i.e. a fresh in-memory cache), the full activity gate (handler offline / beyond `ProximityMeters` / at the boundary / failed `HasK9Access` re-check / handler not in a configured department), the K9-role-only pre-filter, and two no-schema-degradation paths (missing/empty `milestones` config, and an erroring `MySQL.single.await` simulating a pre-migration database) | Indirectly, via the real `CreateThread`/`Wait` sweep loop (stepped through `fixtures/sandbox.lua`'s coroutine thread runner), against a real `k9_partnerships`-shaped in-memory row store with real UPDATE...WHERE race-guard semantics, never a reimplementation of "should only grant once" |
| `server/search.lua` | `GetContrabandAlertTier` (a test-seam wrapper over the file-local `ResolveAlertTier` that landed mid-pass — see "What's NOT covered" history below) — `Config.ContrabandAlertTiers` boundary resolution (`>=` at a threshold vs. one below it), the mandatory zero-weight `'clean'` baseline, top-tier resolution for a large weight, and a negative-weight defensive-input case; also pins the REAL current behavior that this wrapper returns the live `Config.ContrabandAlertTiers[n]` table reference, not a defensive copy (unlike `progression.lua`'s `CopyTier`) | Directly — resource-global (no `local`), added specifically as a test/inspection seam per that file's own FILE-TO-FILE CONTRACT |

118 test cases total across 7 spec files, all currently passing against the
real, unmodified source.

### `ClampLimit`'s hostile-input battery, specifically

`server/admin.lua`'s `ClampLimit` was flagged as a place a review found it
could pass a non-integer to `string.format('%d')` and throw. `admin_spec.lua`
locks in the real, currently-observed behavior for `nan`, `-nan`, `inf`,
`1e400`, `-1e400`, plain floats, negatives, zero, and whitespace-padded
numerics — driven through the actual `RegisterCommand` handler and the real
`string.format('... LIMIT %d', limit)` call, not a reimplementation. One
test's own comment documents the exact reason "nan"/"inf" are currently safe
on this Lua build (`tonumber("nan")` returns `nil` here, so it falls back to
the caller-supplied default rather than reaching `ClampLimit`'s numeric
branches as a real NaN) — if a future Lua/libc combination ever changes that,
this suite fails loudly instead of the bug silently reappearing.

## What's NOT covered, and why

- **`server/search.lua`'s `ResolveAlertTier`** was `local` and uncovered
  when this pass started (see this suite's own prior write-up, preserved in
  git history) — a `GetContrabandAlertTier` test-seam wrapper landed mid-pass
  (another agent, following the exact recommendation this README previously
  made), re-verified directly against the current tree rather than assumed,
  and is now covered by `search_spec.lua`. Recorded here as resolved, not
  deleted outright, so a future reader can see this gap was real and was
  closed, not merely forgotten about.
- **`server/tenure.lua`'s `TenureFullyCollected` local cache** behaves
  differently from its own header comment's stated purpose ("purely a
  per-process, in-memory SKIP-CACHE to avoid re-running the SELECT below
  every tick") — `tenure_spec.lua`'s own `DISCREPANCY:` test confirms the
  real code runs the `MySQL.single.await` SELECT **every** tick regardless
  of this cache's state, because the cache is keyed by `row.id`, which is
  only known *after* that same SELECT returns it. This is disclosed as a
  finding, not silently worked around: it costs one extra indexed SELECT
  per online, fully-tenured K9 per `checkIntervalMs` tick forever (a minor,
  bounded cost, not a correctness bug — the actual double-grant protection
  is the persisted `tenure_bonus_tier_granted` column's optimistic-UPDATE
  guard, which the same spec file separately confirms holds). Not this
  suite's file to fix; flagged for whoever next touches `server/tenure.lua`
  to either correct the header comment or make the cache actually skip the
  query (e.g. by keying it on `k9Citizenid` instead of `row.id`).
- **Client-side logic** (`client/*.lua`) is entirely untested here — every
  file in that directory calls real client-only natives
  (`GetEntityCoords`, `DisableControlAction`, ped/camera natives, NUI
  messaging) with no server-side equivalent to sandbox against, and several
  also assume a live `QBX.PlayerData` cache populated by `@qbx_core/modules/
  playerdata.lua`. Same call as above: doable with enough stubbing, but a
  much larger lift than this pass's scope, and no client file currently has
  anything as isolable as `NewCooldown` or `ResolveTier`.
- **Anything requiring a real MySQL/oxmysql/ox_inventory/ox_lib round
  trip** is out of scope by construction — every spec here stubs those at
  the boundary and asserts on what the PRODUCTION code does with the
  stubbed response (query text, params, branching), never on whether a real
  database would accept that query. The CI `sql-table-existence` job
  already covers the "does this table exist" cross-check textually; this
  suite does not duplicate that.
- **`server/cooldowns.lua`'s `StartSweep`** is tested for its eviction
  predicate (see `fixtures/sandbox.lua`'s coroutine-based thread runner),
  but not for real-world timing/interval accuracy — `Wait` is stubbed to
  `coroutine.yield()`, not a real millisecond sleep, by design (a test
  suite should never take wall-clock time to run).

## Adding a new spec

1. `dofile('testkit.lua')` and `dofile('fixtures/sandbox.lua')`.
2. Build a stub table for exactly the natives/globals the target file
   actually calls (start minimal; `lua5.4 spec.lua` will error with the
   exact missing global's name if you miss one).
3. `Sandbox.newEnv({...})`, then `Sandbox.loadInto('../server/whatever.lua',
   env)` — load any of THAT file's own `server/cooldowns.lua`-style
   dependencies into the same `env` first, in the same order
   `fxmanifest.lua`'s `server_scripts` list already requires.
4. Drive the file's real resource-global functions / captured
   `RegisterCommand`/`AddEventHandler` callbacks; assert on observable
   output (captured prints/notifications/queries/events), never on a
   reimplementation of the logic under test.
5. `os.exit(t.summary())` at the end of the file.
6. Never edit the production file to make it more testable — if something
   is unreachable, say so in this README's "What's NOT covered" section
   instead.
