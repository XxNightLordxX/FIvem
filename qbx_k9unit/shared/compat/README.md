# K9Compat — how the auto-detection layer works

This explains `Config.Compat` (bottom of `config.lua`) and the code that
implements it (`shared/compat/*.lua`), for two audiences: the server owner
who wants to plug in a resource this pack doesn't already know about, and
whoever maintains the adapter files themselves.

If you only want to **use** `override` or `custom`, read "For server
owners" below and stop there — you do not need to read the rest.

## For server owners

You almost never need to touch this file. `Config.Compat` in `config.lua`
already does the talking, in plain English, at the top of that block. This
document exists for the one thing that block can't fully spell out: the
exact shape of a `custom` table, if you're plugging in something fully
in-house that nothing here has ever heard of.

### `override` — "I run one specific thing, always use it"

```lua
Config.Compat.Systems.inventory.override = 'my-custom-inventory'
```

This skips scanning entirely for that system and pins it to the named
resource. If that resource isn't actually running, or doesn't support what
this pack needs, that system goes to a safe "not working" state — it does
**not** fall back to scanning your candidate list. That's deliberate:
`override` means "use exactly this one", not "prefer this one".

### `custom` — "I wrote my own, nothing here knows about it"

```lua
Config.Compat.Systems.inventory.custom = {
    OpenStash    = function(...) ... end,
    OpenShop     = function(...) ... end,
    UseItem      = function(...) ... end,
    ItemExists   = function(...) ... end,
    -- server-side only, ignored on the client side and vice versa (see
    -- "Method lists per system" below for exactly which names apply where)
    GetInventoryItems     = function(...) ... end,
    GetContainerFromSlot  = function(...) ... end,
    GetItemCount          = function(...) ... end,
    RemoveItem            = function(...) ... end,
    RegisterStash         = function(...) ... end,
    RegisterShop          = function(...) ... end,
    RegisterHook          = function(...) ... end,
}
```

This wins over everything else, including `override`. Write ONE table per
system containing every function name listed for that system below (both
the client-side and server-side names, in the same table — the code
running on your server only ever checks the half it actually needs for
whichever side it's on, so the other half is simply ignored on that side,
not an error).

**If your table is missing a required function, this pack will NOT
half-work with it.** It treats an incomplete `custom` table the same way it
treats an old/renamed third-party resource: rejected, with the exact
missing function name(s) printed at startup and in `/k9compat` (see
below), falling back to a safe "not working" state for that one system —
never a silent partial success.

### Seeing what it actually found

- **At startup**, if `Config.Compat.logDetectionOnStart` is `true`
  (default), one summary block prints to the server console listing what
  was resolved for every system.
- **In-game**, `/k9compat` (the name is `Config.Compat.diagnosticCommand` —
  change it, or set it to `false` to remove the command entirely) reprints
  that same summary **and** explains why every candidate that was tried and
  rejected got rejected. This command is restricted to High Command (the
  same senior-rank tier `/k9givexp` uses) because it names every script
  your server runs — that's not information for a general player.
- **Live, mid-session**, if `Config.Compat.redetectOnResourceRestart` is
  `true` (default), restarting a resource this pack cares about (e.g.
  `restart ox_inventory`) re-runs detection automatically, and — if
  anything actually changed — prints a fresh summary, with no need to
  restart this whole resource.

## For whoever maintains shared/compat/*.lua

This is the part that matters if you're writing or reviewing
`inventory.lua`, `target.lua`, `framework.lua`, `dispatch.lua` or
`ambulance.lua` in this same folder.

### The one call every adapter file makes

```lua
K9Compat.RegisterAdapter(system, resourceName, factory)
```

- `system` — one of `'inventory'`, `'target'`, `'framework'`, `'dispatch'`,
  `'ambulance'`. Anything else is rejected at registration time with a
  console warning, and does not crash resource start.
- `resourceName` — the literal FiveM resource name this factory knows how
  to wrap (e.g. `'ox_inventory'`). One `RegisterAdapter` call per resource
  your adapter file supports — `inventory.lua` will call this 8 times (once
  per entry in `Config.Compat.Systems.inventory.candidates`), not once.
- `factory` — `function(realm) -> table | nil`. `realm` is exactly the
  string `'client'` or `'server'`, telling you which Lua VM is asking (this
  file is a shared script, loaded independently on both — see `core.lua`'s
  own header for the full reasoning). Return a table shaped for that realm,
  or return `nil` if this resource is present but you've determined it
  can't actually be used right now (e.g. detected but an internal API you
  need isn't there) — `nil` means "skip me, try the next candidate", not
  "crash".

**You do not need to check `GetResourceState` yourself before returning a
table.** `core.lua` already confirms the named resource is `'started'`
*before* it ever calls your factory. You also do not need to guard against
your own factory throwing — `core.lua` calls every factory inside `pcall`
and treats a throw exactly like a `nil` return (skip, log the reason,
continue).

### Method lists per system (the exact contract, copy from here)

This table is the single source of truth — it lives in code as
`K9Compat.RequiredMethods` in `core.lua`. If it and this file ever
disagree, the code wins; open an issue against this README, not the other
way around.

| system      | realm    | required methods |
|---|---|---|
| `inventory` | `client` | `OpenStash`, `OpenShop`, `UseItem`, `ItemExists` |
| `inventory` | `server` | `GetInventoryItems`, `GetContainerFromSlot`, `GetItemCount`, `RemoveItem`, `RegisterStash`, `RegisterShop`, `RegisterHook` |
| `target`    | `client` | `AddGlobalPlayer`, `AddGlobalVehicle`, `AddGlobalObject`, `AddModel`, `AddSphereZone`, `Remove` |
| `target`    | `server` | *(none)* |
| `framework` | `client` | `GetPlayerData` |
| `framework` | `server` | `GetPlayer`, `GetPlayerByCitizenId`, `GetCitizenId`, `GetJob` |
| `dispatch`  | `client` | *(none)* |
| `dispatch`  | `server` | `Alert` |
| `ambulance` | `client` | *(none)* |
| `ambulance` | `server` | `IsDowned` |

A table returned for a realm with an empty required-methods row (e.g.
`target.server`) is accepted as-is once it's a non-nil table — there's
nothing to verify against, since there's nothing that realm needs from that
system today.

**Parameter shapes and return values for each method are NOT defined by
this file or by `core.lua`.** `core.lua` is generic plumbing: it only knows
method *names*, never what any of them take or return — that's owned by
whichever real resource each adapter wraps. When in doubt, match the
calling convention of the reference resource this pack was built against
for that system (`ox_inventory` for `inventory`, `ox_target` for `target`,
`qbx_core` for `framework`), since that's what every OTHER adapter for the
same system needs to stay interchangeable with.

### Resolution order (highest priority first)

1. `Config.Compat.Systems[system].custom` — if set AND it passes
   verification (every required method for the current realm is present as
   a function), it's used, full stop. If set but it FAILS verification,
   that system resolves to the no-op stub — it does **not** fall through to
   `override` or `candidates`. `custom` is an absolute pin, not a
   preference.
2. `.override` — a single resource name. If a factory is registered for it,
   it's started, and it verifies, it's used. If any of those three things
   isn't true, that system resolves to the no-op stub — same "absolute pin,
   no fallthrough" rule as `custom`.
3. `.candidates`, walked in array order. The first one that has a
   registered factory, is `'started'`, and verifies wins. Only runs at all
   when BOTH `Config.Features.ResourceAutoDetect` and
   `Config.Compat.autoDetect` are `true` — either being `false` skips this
   tier only (custom/override still work either way).
4. Nothing resolved → the no-op stub. Every required method for the current
   realm exists and is callable; every one returns `nil`; the reason is
   logged to console exactly once (never per call).

### What `K9Compat.Get(system)` actually hands you

Never `nil`, and every method on it is already `pcall`-safe — if the real
underlying resource's function throws, your call to
`K9Compat.Get('inventory').ItemExists(name)` gets `nil` back instead of an
error propagating into your code, logged once per (system, resource,
method) rather than every time it's called. You do not need your own
`pcall` or `type(...) == 'function'` guard around a call through
`K9Compat.Get(...)` — that safety is already built in. (You still need your
own `pcall`/guards anywhere else your own file calls a third-party export
directly, outside of `K9Compat` — this only covers what comes back from
`Get`.)

### Security note (worth restating here, not just in `core.lua`)

None of this — `RegisterAdapter`, `Get`, `Which`, `Report`, `Redetect` — is
ever consulted by any rank, certification, ownership, or XP check anywhere
in this resource. Those all remain server-side and independent of whatever
was detected. If your adapter file is tempted to let a detected resource's
answer influence an authorization decision (e.g. "let them proceed because
the inventory says X"), that's out of scope for an adapter and belongs, if
anywhere, in the file that owns that authorization check — not here.
