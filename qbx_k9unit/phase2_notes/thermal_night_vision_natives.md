# Thermal Vision / Night Vision — Native Verification (Phase 2, §6.3/§6.4/§7)

Status: SPEC.md §7 and §6.3's claim needs a correction, not just confirmation.
See "Verdict" below.

## What SPEC.md currently claims

- §6.3: "Thermal vision and night vision use native `SetTimecycleModifier`/
  nightvision natives only — no custom shader work."
- §7 table row: "Thermal / night vision | `SetTimecycleModifier`/nightvision
  natives — this is genuinely native-only and fully achievable ... | Nothing
  extra needed."

This bundles both effects under `SetTimecycleModifier` (with "nightvision
natives" as a vague second bucket). That's not accurate for thermal.

## Confirmed natives

### Night vision — `SetNightvision(BOOL toggle)`
- Client-side native. Toggles the game's built-in night-vision
  post-process render filter on/off for the local player's screen.
- Paired query native: `IsNightvisionActive()` → BOOL.
- Confirmed via the CitizenFX C# SDK wrapper (`Game.cs`,
  `citizenfx/fivem` repo), which exposes it as a plain boolean property:
  ```csharp
  public static bool Nightvision {
      get { return API.IsNightvisionActive(); }
      set { API.SetNightvision(value); }
  }
  ```
  Doc comment: "Gets or sets a value indicating whether to render the world
  with a night vision filter." A get/set boolean property wrapper is a
  strong signal this is a one-shot state toggle, not a per-frame call.
- Real-world usage pattern (ESX-Binoculars `client.lua`, FunctionalGear,
  Arkadia's `heli_client.lua`) confirms this empirically: every resource
  found calls `SetNightvision(true/false)` exactly once per state
  transition (on toggle-on, on toggle-off, on cleanup) — never inside a
  `CreateThread`/`Wait(0)` maintenance loop.

### Thermal vision — `SetSeethrough(BOOL toggle)`, NOT `SetTimecycleModifier`
- Client-side native, hash `0x7E08924259E08CE0`, in the `GRAPHICSAPI`
  namespace per docs.fivem.net search indexing. Toggles the game's built-in
  "Heatvision" post-process render filter — this is GTA's native thermal-
  vision effect (the same one used for sniper thermal scope, heli FLIR,
  etc. in singleplayer), not a timecycle modifier at all.
- Paired query native: `IsSeethroughActive()` → BOOL.
- Confirmed via the same CitizenFX C# SDK wrapper:
  ```csharp
  public static bool ThermalVision {
      get { return API.IsSeethroughActive(); }
      set { API.SetSeethrough(value); }
  }
  ```
  Doc comment: "Gets or sets a value indicating whether to render the world
  with a thermal vision filter."
- Real-world resources (ESX-Binoculars, Arkadia heli_client.lua,
  FunctionalGear) confirm the same one-shot toggle pattern as nightvision —
  e.g. ESX-Binoculars' vision-cycle function:
  ```lua
  function ChangeVision()
    if vision_state == 0 then
      SetNightvision(true); vision_state = 1
    elseif vision_state == 1 then
      SetNightvision(false); SetSeethrough(true); vision_state = 2
    else
      SetSeethrough(false); vision_state = 0
    end
  end
  ```
  Both are cleared explicitly (`SetNightvision(false)` /
  `SetSeethrough(false)`) on mode exit / helicam exit — again a discrete
  state transition, not a maintenance loop.

## Is there any `SetTimecycleModifier` involvement at all?

No — for thermal and night vision specifically, no timecycle modifier name
was found in any confirmed source (SDK wrapper, real resource code, or doc
search results) tied to `SetNightvision`/`SetSeethrough`. `SetTimecycleModifier`
is a real, separate native (used correctly elsewhere in this same spec, e.g.
§6.6's contraband screen-filter effect, which legitimately does reuse an
existing GTA "drug effect" timecycle modifier). But thermal/night vision
don't need it — they have their own dedicated, purpose-built toggle natives
instead. I did not find or invent any modifier name like `nv_high` for this
purpose; no such modifier is used by the confirmed nightvision/thermal path,
so it's a non-answer, not an omission — the search for a timecycle-modifier
name for these two effects was based on a false premise from SPEC.md §7.

## Toggle-and-forget confirmation

Both natives are genuinely fire-and-forget booleans, not per-frame calls:
- The C# SDK models them as simple get/set boolean properties, which is
  inconsistent with a native that needs re-assertion every tick.
- Every real-world Lua resource found (ESX-Binoculars, Arkadia heli_client,
  FunctionalGear-adjacent gear scripts) calls them exactly once per state
  change (on-enable, on-disable, on-cleanup) with zero examples of a
  `CreateThread`/`Wait(0)` loop repeatedly re-calling `SetNightvision`/
  `SetSeethrough` to "keep it on."

One practical caveat for coder-frontend's design (not a per-frame
requirement, but a state-transition one): because these are local-client
global render toggles, other systems on the client can implicitly want them
off — e.g. helicam/vehicle-camera scripts and scope/binocular scripts
explicitly call `SetNightvision(false)`/`SetSeethrough(false)` on their own
cleanup paths. For qbx_k9unit this means the toggle handler should
explicitly force both off on the relevant exit paths (player death,
disconnect, losing K9 access/certification mid-session per §4.4's
auto-revoke, and — if thermal/night vision is scoped to only-while-playing-
the-K9 — a model swap), not because the native decays on its own, but
because nothing else in the resource will turn it off for you if the K9
player's access state changes out from under an active toggle.

## Verdict on SPEC.md §7 / §6.3

**The bottom-line claim ("genuinely native-only, no custom shader work,
fully achievable") is correct and actually holds even more strongly than
stated** — both effects are backed by dedicated, purpose-built toggle
natives, which is a cleaner story than the vague "SetTimecycleModifier/
nightvision natives" phrasing suggested.

**But the specific native attribution is wrong and should be corrected:**
- Night vision → `SetNightvision(bool)` / `IsNightvisionActive()`. This part
  was directionally right ("nightvision natives").
- Thermal vision → `SetSeethrough(bool)` / `IsSeethroughActive()` — **not**
  `SetTimecycleModifier`. SPEC.md's phrasing implies thermal might need a
  timecycle-modifier name to be sourced/tuned; it doesn't. This is simpler
  to implement than the spec suggests (no modifier-name hunting/tuning at
  all), but the current wording is factually inaccurate about which native
  does the work.

**Recommended spec fix (§6.3 bullet and §7 table row):** replace
"`SetTimecycleModifier`/nightvision natives" with "`SetNightvision`/
`SetSeethrough` toggle natives" in both places.

## Sources
- [SetNightvision - FiveM Natives @ Cfx.re Docs](https://docs.fivem.net/natives/?_0x18F621F7A5B1F85D=) (docs.fivem.net itself is proxy-blocked in this environment; confirmed instead via search-index summary and the citizenfx SDK source below)
- [SetSeethrough - FiveM Natives @ Cfx.re Docs](https://docs.fivem.net/natives/?_0x7E08924259E08CE0=)
- [citizenfx/fivem — code/client/clrcore/External/Game.cs](https://github.com/citizenfx/fivem/blob/master/code/client/clrcore/External/Game.cs) — authoritative SDK source confirming both natives, their pairing with `IsNightvisionActive`/`IsSeethroughActive`, and boolean-property (toggle) semantics.
- [ESX-Binoculars/client.lua](https://github.com/ZAUB1/ESX-Binoculars/blob/master/client.lua) — real-world one-shot toggle usage pattern for both natives.
- [FiveM-Arkadia_ heli_client.lua](https://github.com/ItsikNox/FiveM-Arkadia_/blob/master/resources/%5Besx%5D/%5Bothers%5D/esx_utils/heli_client.lua) — real-world usage, explicit off-on-cleanup pattern.
- [AJMyers1991/FunctionalGear config.lua](https://github.com/AJMyers1991/FunctionalGear/blob/main/config.lua) — nightvision/thermal goggle item config context.

Note: `docs.fivem.net`, `runtime.fivem.net`, and `forum.cfx.re` are all
blocked by this environment's network egress proxy, so the primary CFX
native docs pages could not be fetched directly — confirmation instead
relies on (a) the official CitizenFX SDK source on GitHub, which wraps
these exact same natives with documented semantics, and (b) multiple
independent real-world resource implementations showing consistent usage.
This is strong corroboration but is a one-notch-removed source rather than
the docs page itself; if a future task needs the literal docs.fivem.net
page content, it will need a different network path.
