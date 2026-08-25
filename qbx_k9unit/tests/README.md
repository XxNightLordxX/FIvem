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

**`run.sh` glob-discovers `*_spec.lua`, which means an incomplete spec file
sitting in this directory turns the WHOLE suite red**, not just the file
being written. This has happened during real work on this suite (two specs
being authored concurrently briefly made a full `./run.sh` run look broken
while every already-committed spec was fine). If you're mid-write on a new
spec, don't treat a red `./run.sh` as a signal the committed suite regressed
— run the committed files individually (`lua5.4 admin_spec.lua`, etc.) to
check those, and only trust the full-suite total once your new file is
finished and self-consistent.

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

### The sandbox's `locale()` is real, not a stub — every notify-path spec doubles as a locale-key check

`Sandbox.newEnv` (see `fixtures/sandbox.lua`) wires a real `locale(key, ...)`
into every sandboxed environment by default — it opens and parses the actual
`../locales/en.json` (a small hand-rolled JSON reader good enough for that
file's nested-object-of-strings shape, not a general parser) and looks up
`group.leaf` exactly the way ox_lib's own `flattenDict` would. Unlike real
ox_lib, which silently returns the key itself when a key is missing (so a
missing key only ever shows up as odd text in-game), this sandbox's
`locale()` **raises** on a missing/non-string key.

Practical consequence for anyone adding a spec: if the production file you're
loading calls `locale('some.key')` on any code path your test exercises, that
call is NOT stubbed away — it runs for real against `locales/en.json`. So
every test that drives a `NotifyPlayer(..., locale('x.y'), ...)`-shaped call
(or any other real `locale()` call) is *also*, for free, a regression check
that `x.y` still exists in `en.json` with a string value. This has already
caught real drift in this suite (a locale key referenced by production code
but renamed/removed from `en.json` fails the test with `"locale key missing
from locales/en.json: x.y"`, not a silent pass). `certifications_spec.lua`
and `kennel_spec.lua` both call this out explicitly in their own header
comments and build expected notification text by calling
`Sandbox.locale(...)` themselves rather than hardcoding a copy of the English
string, specifically so the spec can never drift from `en.json`'s actual
wording while still asserting real content. Do the same in any new spec that
asserts on notify text: call `Sandbox.locale(...)` for the expected value,
don't hand-copy the English string from `en.json` into the spec file.

If a spec genuinely needs to test `locale()`-calling code WITHOUT this
raise-on-missing behavior (e.g. deliberately testing a missing-key path),
override `env.locale` with your own stub after `Sandbox.newEnv()` returns —
the same "reassign after the fact" mechanic every other override in this
suite already uses.

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
| `server/certifications.lua` | `HasK9Access`/`RefreshCertificationCache`/`IsConfiguredK9Model` directly; `GrantCertification`/`RevokeCertification`/`RevokeCertificationOffline`/the `QBCore:Server:OnJobUpdate` auto-revoke handler indirectly — the authorization root nearly every other feature in this resource gates on, previously at ZERO direct coverage. Also records a genuine finding: unlike `server/propattachment.lua`/`server/bonetool.lua`/`server/progression.lua`/`server/admin.lua`/`server/search.lua`, this file has no file-load-time `assert(...)` on `Config.Departments`/`Config.Peds`, so a malformed entry fails silently later rather than loudly at resource start | Directly for the three resource-globals; indirectly for the `local` functions, via the real captured `RegisterNetEvent`/`RegisterCommand`/`AddEventHandler`/`onResourceStart` entry points, same convention as `admin_spec.lua`/`progression_spec.lua`. Loads the real `server/cooldowns.lua` into the same env first for `CertifyActionCooldown` |
| `server/kennel.lua` | All four `RegisterNetEvent` handlers (`requestDeployKennel`/`confirmKennelPlaced`/`cancelKennelPlacement`/`requestPickupKennel`) plus its `playerDropped`/`onResourceStop` cleanup, loaded alongside the real `server/cooldowns.lua` and `server/entities.lua` so `DeployCooldown` and every `ResolveNetworkEntity` call are the real primitives, not reimplementations. One fresh sandbox per test (never shared), since `Kennels`/`PendingKennelPlacements` are file-lifetime `local` upvalues that would otherwise leak state between unrelated cases. Its own header records a real bug caught live, mid-authorship, in a concurrently-edited version of the production file (three silent re-validation rejections inside `confirmKennelPlaced` that could strand a real networked object) — read there for the full account rather than assumed fixed here | Directly for the event handlers (captured registrations); `HasK9Access`/`NotifyPlayer` are stubbed, not loaded, since each is already covered by its own file's spec |
| `server/exports.lua` + `client/exports.lua` | BOTH public cross-resource API surfaces this resource ships (9 server exports, 18 client exports) against the real, unmodified files — previously zero direct coverage despite being the only surface other resources actually call. Covers every documented export's happy path, the exact count of exports registered (no more, no fewer), and each of the three documented safety nets (argument type guard / wrapped-global existence guard / pcall) via hand-written controllable stubs for the wrapped globals (deliberately not the real `server/progression.lua` etc., which are already directly covered by their own specs — this file's job is testing the export wrappers' OWN guard behavior in isolation). Also records inline FINDINGS (not fixed here) where an export doesn't validate its wrapped global's return type against its own doc comment, unlike neighboring exports in the same file that do | Directly — every export under test is a captured registration (`exports(...)`/`exports.qbx_k9unit:...`-shaped stub) from the real file |

434 test cases total across 12 spec files, all currently passing against the
real, unmodified source (from `tests/run.sh`'s own per-file "N passed, M
failed" output, summed — see "A count you must run, not grep" below for why
this number cannot be derived any other way). Per file: exports 135,
defense 54, certifications 47, kennel 39, cooldowns 32, admin 28, main 25,
entities 20, tenure 19, progression 14, search 12, notify 9.

NOTE ON THIS NUMBER: it was 355 across 10 files an hour before this line was
written. `defense_spec.lua` (54) and `main_spec.lua` (25) landed in between.
Re-run rather than trusting it; that is the whole point of the section
below.

### A count you must run, not grep

Counting `t.test(` occurrences in the `*_spec.lua` files understates the
real number and should never be used as a substitute for running the suite.
`exports_spec.lua` alone is the clearest case: its "13 zero-argument boolean
exports" section is a single `for _, exportName in ipairs(CLIENT_BOOLEAN_EXPORTS)
do ... end` loop wrapping 4 `t.test(...)` calls, so those 4 lines of source
register 52 actual test cases (13 × 4) at runtime — a static grep sees 4.
Across the whole suite, `run.sh`'s own per-file summary line (`testkit.lua`'s
`summary()`, `"%d passed, %d failed"`) is the only source of truth for a case
count; the table above and the total here were produced by actually running
`tests/run.sh`, not by counting source lines.

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
- **`server/tenure.lua`'s `TenureFullyCollected` local cache does not skip
  the SELECT it might look like it exists to skip.** `tenure_spec.lua`'s own
  `DISCREPANCY:` test confirms the real code runs the `MySQL.single.await`
  SELECT **every** tick regardless of this cache's state, because the cache
  is keyed by `row.id`, which is only known *after* that same SELECT returns
  it — the cache can only short-circuit the (cheaper) tier-walk/UPDATE work
  strictly after the SELECT, never the query itself. **Note for whoever next
  reads this:** `server/tenure.lua`'s own header comment on that local used
  to claim the opposite (that the cache exists "to avoid re-running the
  SELECT below every tick") — that comment has SINCE BEEN CORRECTED in the
  production file itself (it now says outright: "this does NOT skip the
  SELECT below... despite an earlier revision of this comment claiming it
  did", and explains why a pre-query skip isn't safely buildable without a
  separate `k9Citizenid`-keyed cache this file doesn't have invalidation
  hooks for). So this is no longer a doc-vs-code mismatch — the header and
  the test now agree — but the underlying cost this test pins down is still
  real: one extra indexed SELECT per online, fully-tenured K9 per
  `checkIntervalMs` tick forever (a minor, bounded cost, not a correctness
  bug — the actual double-grant protection is the persisted
  `tenure_bonus_tier_granted` column's optimistic-UPDATE guard, which the
  same spec file separately confirms holds). `tenure_spec.lua`'s own test
  name/comments still narrate this as the header "claiming" the cache skips
  the SELECT — that's now describing the header's PRE-correction wording, so
  read it as "here's the behavior that was once mis-documented and no longer
  is," not as an open contradiction. Kept here as a disclosed, regression-
  guarded cost, not a bug to fix.
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
   reimplementation of the logic under test. If you assert on notify text
   that came from a `locale(...)` call, build the expected string by calling
   `Sandbox.locale(...)` yourself, not by hand-copying the English string
   from `en.json` — see "The sandbox's `locale()` is real" above for why
   (that same real `locale()` will also raise loudly if the production code
   references a key that doesn't exist in `en.json`, which is itself a
   useful check to get for free).
5. `os.exit(t.summary())` at the end of the file.
6. Never edit the production file to make it more testable — if something
   is unreachable, say so in this README's "What's NOT covered" section
   instead.
