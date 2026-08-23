# Phase 2 design note: Thermal Vision & Night Vision

Author: coder-frontend (client-side script logic lens)
Date: 2026-08-23
Status: **DESIGN NOTE ONLY — no `.lua` implementation code written or
intended by this file.** Written in two passes: an initial pass before a
detailed Phase 2 spec existed, and this **revised pass** after
product-manager's real Phase 2 spec landed in `SPEC.md` §11 (§11.2's
`Config.Vision`, §11.3's `client/vision.lua` file-plan row, §11.5's
acceptance criteria, §11.6's reality-check refinements). **SPEC.md §11 is
now the authoritative source for every decision it makes explicitly** —
this note exists to add implementation-level detail SPEC.md leaves
described-but-not-mechanized (the exact cleanup/maintenance-thread shape,
the mutual-exclusion helper shape, the function-naming contract), not to
re-litigate anything §11 already settled. Where this note's *earlier* draft
guessed differently than what §11 confirmed, that's called out explicitly
below rather than silently rewritten, so anyone diffing against the
original file/git history can see what changed and why.

**Verification status:** native-api-assistant has independently confirmed
the two natives below against the CitizenFX SDK source
(`Game.cs`'s `Seethrough`/`Nightvision` boolean properties) plus multiple
real-world FiveM implementations — this is now a **confirmed, cited**
finding (SPEC.md §11.6), not the "well-established community knowledge,
unverified this session" caveat this note's first draft had to carry. My
earlier direct `SendMessage` to native-api-assistant this session had
returned "not reachable"; the confirmation instead arrived via the
coordinator relaying SPEC.md §11.6's already-published text, which I've
read directly (`SPEC.md` lines ~1354–1400) rather than taking secondhand.

---

## 1. Toggle UX: keybind only, mirroring `ToggleK9Camera()` exactly — settled by §11.3, not a radial item

**SPEC.md's confirmed decision (§11.2, §11.3, §11.5):** two independent
`RegisterKeyMapping` keybinds, driven by `Config.Vision.Thermal.toggleKey`
(`'K'`) and `Config.Vision.Night.toggleKey` (`'J'`), living in a **new**
`client/vision.lua` file. **Not** added to the "K9 Unit" radial submenu —
§11.3's `client/radial.lua` row states this explicitly: "Vision toggles and
door interaction are not added to the radial (keybind and ox_target-zone
respectively...), consistent with the camera toggle's existing precedent
of not being a radial item either."

**Correction to this note's own earlier draft:** the first pass of this
note proposed a radial item as a *secondary* entry point alongside the
keybind, reasoning by analogy to the leash mechanic's dual ox_target +
radial entry points. §11.3 settles this the other way — keybind-only,
matching the camera toggle's precedent exactly, not the leash's dual-entry
precedent. The camera analogy is the correct one to draw here (both are
perception/viewpoint QoL controls a player wants to flip instantly without
navigating a wheel), not the leash analogy (a deliberate, consent-gated,
lower-frequency action where wheel overhead is fine) — keeping only the
keybind avoids a second, unnecessary code path for a control that's
explicitly framed as fast/reactive. No radial changes belong in
`client/vision.lua`'s scope.

**Config-gated registration, not just config-gated behavior:** per §3's
hard requirement ("read at the point where that feature would activate...
command registration... not read once at resource start and then
ignored"), `RegisterCommand`/`RegisterKeyMapping` for each toggle must only
run `if Config.Features.ThermalVision` / `if Config.Features.NightVision`
respectively, each independent of the other — mirroring
`client/radial.lua`'s existing convention of only pushing a flagged item
into its array at file-load time, not `ToggleK9Camera`'s unconditional
registration (camera has no `Config.Features` entry to gate on at all;
thermal/night vision do, so unlike camera they must be gated).

## 2. Natives — CONFIRMED, not the originally-asserted `SetTimecycleModifier`

### 2a. Thermal vision — `SetSeethrough(BOOL toggle)` / `IsSeethroughActive()`

SPEC.md §7's original claim ("`SetTimecycleModifier`/nightvision natives
only") is **refined, not reversed**, by §11.6: the concrete, better-fitting
native for thermal vision is `SetSeethrough(true/false)` — GTA V's built-in
heat-vision effect (the same one used for the base game's "Predator" random
event and the Cayo Perico heist's thermal goggles item), which genuinely
highlights peds as heat sources, closer to the real intent of "K9 thermal
vision" than a generic timecycle-modifier reskin. Still fully native-only,
zero new shader/asset work — the "no custom shader work" half of §7's
original claim holds; only the specific API surface named needed
correcting. `IsSeethroughActive()` is the paired getter, confirmed to exist
alongside the setter (useful as the source of truth for
`IsThermalVisionActive()`, §7 below, rather than tracking a second,
independently-desyncable local boolean).

### 2b. Night vision — `SetNightvision(BOOL toggle)` / `IsNightvisionActive()`

Confirmed achievable exactly as SPEC.md §7 originally claimed —
`SetNightvision(true/false)` is the standard native NV-goggle effect, fully
native-only, zero new assets. `IsNightvisionActive()` is the paired getter.

### 2c. Toggle-and-forget — no per-frame maintenance thread needed to *hold* the effect

Both natives are genuinely toggle-and-forget per native-api-assistant's
confirmation (§11.6): setting the boolean once is sufficient, there is
**no need for a `Wait(0)` per-frame re-assertion loop** the way
`DisableControlAction` (used by this resource's existing
`AgilityBasicJump` gate in `client/movement.lua`) requires. This matters for
`resource-performance-profiler`'s lens: `client/vision.lua` should NOT run
a tight per-frame thread just to keep the effect "on" — the only thread
this file needs is the low-frequency (~1s) maintenance/cleanup thread
described in §6, and only while at least one effect is currently active.

### 2d. Cross-reference, do not confuse with §6.6's screen-filter effect

§6.6's contraband-ingestion screen effect (`Config.Features.ContrabandScreenFX`,
not yet Phase-2-detailed in §11) genuinely and correctly uses
`SetTimecycleModifier` (reusing an existing GTA "drug effect" style
modifier) for a color-grading overlay — a real, separate, already-correct
use of the timecycle-modifier system elsewhere in this spec, unrelated to
thermal/night vision's natives and gated by its own, different
`Config.Features` flag. Nothing in this note touches that system.

---

## 3. Access gating: `IsOwnModelK9()` only — settled by §11.5, not `CanShowK9UI()`

**SPEC.md's confirmed decision (§11.5):** thermal/night vision gate on the
cheap, local, free `IsOwnModelK9()` check only — the **same** judgment call
`client/movement.lua`'s header already made for the camera toggle — not
the full server-backed `CanShowK9UI()` combinator that Bark/Sit/Leash/
Vehicle use. §11.5's own text states the reasoning: "thermal/night vision
is presented in SPEC.md as the K9's own innate perception, not a granted
departmental privilege." Apply identically to both Thermal and Night
vision, per §11.5's explicit "whichever answer is chosen, apply it
identically to both... for consistency."

**Correction to this note's own earlier draft:** the first pass of this
note recommended the *opposite* — gating on `CanShowK9UI()` — reasoning
from §6.3's placement of these flags alongside ScentTracking/BloodTracking
(capabilities of a certified, employed K9). §11.5 resolves the ambiguity
the other way, explicitly citing the exact same tension this note's first
draft raised and choosing the camera-toggle precedent instead. Deferring
to §11.5 as the settled answer — implementation should use
`IsOwnModelK9()` only, matching `ToggleK9Camera()`'s exact gating shape,
not this note's earlier guess.

**Practical effect of this choice:** an uncertified K9-model player (or one
whose job isn't in `Config.Departments`) can still toggle thermal/night
vision, exactly as they can already toggle the first/third-person camera —
this is intentional and consistent, not a gap to close later.

---

## 4. Mutual exclusivity — confirmed judgment call (§11.5), not an engine requirement

**SPEC.md's confirmed decision (§11.5):** "Thermal and night vision are
mutually exclusive at any given moment (toggling one off the other if both
were somehow active) — not explicitly required by SPEC.md's original
wording, but a reasonable default given both are full-screen post-effects
that would otherwise visually conflict; flagged here as a judgment call,
not a mandate." This matches this note's own first-draft reasoning exactly
(both are competing full-screen post-process overlays) — no change needed
here, just confirming the earlier guess and the settled spec now agree.

**Implementation shape (described, not coded):** each `Toggle*Vision()`
function's "turning on" branch should check whether the *other* effect is
currently active (via its `Is*Active()` getter, §2 above — the
authoritative native-backed state, not a locally-tracked boolean that
could desync) and call that other effect's own "turn off" path first,
before enabling itself. Keep this as one small shared internal helper
inside `client/vision.lua` (e.g., logically "turn off whichever of the two
isn't the one being requested") rather than duplicating the
check-and-turn-off logic once per toggle function.

---

## 5. Config interaction — `Config.Features.ThermalVision` / `NightVision` remain fully independent

Nothing about mutual exclusivity at *runtime* couples the two
`Config.Features` flags together — a server can enable exactly one of the
two (e.g. `ThermalVision = true, NightVision = false`), in which case only
that one keybind/command gets registered at all (§1) and the mutual-
exclusion check in §4 is moot for that server (there's never a second
active effect to turn off). `Config.Vision.Thermal`/`Config.Vision.Night`
each carry only their own `toggleKey` per §11.2's schema — no shared
sub-table, keeping the two configs symmetric and independently editable.

---

## 6. Cleanup / exit-path requirements — the new must-have surfaced during verification (§11.6)

**SPEC.md §11.6's new requirement, not present in the original design:**
because both natives are global, local-render toggles with **no automatic
reset**, `client/vision.lua`'s toggle handlers must explicitly force both
`SetSeethrough(false)` and `SetNightvision(false)` off on **every** exit
path, not just the manual "player pressed the key again" path:

1. **Manual toggle-off** — trivial, already covered by the toggle function
   itself (§1/§4).
2. **Resource stop** (`/restart qbx_k9unit` or a server shutting the
   resource off) — mirrors `client/vehicle.lua`'s existing
   `onResourceStop` safety-net pattern for its own persistent native
   states (frozen/invisible/attached ped) almost exactly: an
   `AddEventHandler('onResourceStop', function(resourceName) ... end)`
   handler, guarded on `resourceName == GetCurrentResourceName()`, forces
   both natives off (independent of which one is actually on — safe to
   call `SetSeethrough(false)`/`SetNightvision(false)` unconditionally even
   if a given effect was never on this session, since these are idempotent
   boolean toggles, not stacking counters).
3. **Disconnect — very likely already covered by #2, not a separate hook.**
   FiveM's client runtime stops every currently-loaded resource (firing
   each one's `onResourceStop`) as part of a player disconnecting from a
   server, before either returning to the main menu or reconnecting
   elsewhere — this is standard, widely-relied-upon FiveM client behavior
   (it's exactly why `onResourceStop` handlers are the common idiom for
   "clean up on disconnect" across the FiveM ecosystem, not just for
   in-place restarts). The concern this exit path exists to close is real
   and non-obvious: `SetSeethrough`/`SetNightvision` are engine-level
   render toggles that could plausibly persist across a disconnect-and-
   reconnect-to-a-different-server within the *same* running FiveM game
   process (unlike a Lua script's own variables, which do reset), which
   would be a jarring, immersion-breaking bug on an unrelated server if
   left uncleared. High confidence this is the same underlying mechanism
   as #2 above and needs no separate implementation — flagged as "verify
   this assumption once real code exists" rather than asserted with 100%
   certainty, since I have not independently tested whether these specific
   two natives survive a `restart`/disconnect the same way
   `AttachEntityToEntity`/`FreezeEntityPosition` do (§11.6 asserts they
   have "no automatic reset," which is the same category of persistence
   this reasoning depends on).
4. **Player death** — not automatic per §11.6's own framing (the natives
   have "no automatic reset" full stop, and nothing in the CitizenFX
   source cited suggests death is a special case). Needs an active check.
   Proposed mechanism (see maintenance-thread design below): poll
   `IsEntityDead(PlayerPedId())`.
5. **Certification auto-revoked mid-session (§4.4)** — needs an active
   check; **no existing structured signal exists for this today.**
   `server/certifications.lua`'s manual-revoke and
   `QBCore:Server:OnJobUpdate` auto-revoke paths currently only send a
   generic `TriggerClientEvent('ox_lib:notify', target, {...})` — a
   library-internal notification, not a `RegisterNetEvent`
   `client/vision.lua` (or anything else) could subscribe to for a
   structured "you just lost K9 access" signal. Proposed mechanism: see
   below.

   **Explicit tension worth naming, not silently smoothing over:** per §3
   above, the toggle itself is deliberately gated on `IsOwnModelK9()`
   only — losing certification/job does **not** by itself revoke the
   *ability* to toggle thermal/night vision on again a moment later (a
   K9-model player who just got fired can still press `K`/`J` and get the
   effect right back). Forcing it off *once*, at the moment of the
   auto-revoke event, is therefore a one-time defensive UX courtesy
   (§11.6's stated rationale: "a player left in a stuck thermal/NV view
   after losing K9 access would be a real bug") rather than a security
   enforcement — it does not, and structurally cannot, prevent the player
   from turning it straight back on, since that path was never gated on
   certification in the first place. Implementation should treat this as
   "clear it once on the revoke event," not build out a persistent
   "vision disabled while uncertified" state machine that would
   contradict §3's settled gating decision.

### Proposed maintenance-thread shape (described, not coded)

A single lightweight thread inside `client/vision.lua`, started only when
either effect transitions to active (not running idly at all times — keeps
with the "don't run a loop when the feature isn't in use" principle), that
on each ~1000ms tick (this is a cleanup/safety poll, not a rendering
concern, so a full-second interval is appropriate — no sub-frame precision
needed for any of the three conditions below) checks, in order:

- `IsEntityDead(PlayerPedId())` → if true, force both natives off (§6.4).
- `not IsOwnModelK9()` → if the player's live model has stopped being a
  configured K9 model (the same rare appearance-swap edge case SPEC.md §9
  item 8 flags for the certification system, applied here by the same
  logic the toggle's own gate already uses) → force both off. Not
  explicitly required by §11.6's list, but a direct, low-cost corollary of
  the exact gate chosen in §3 — if the gate that allows turning it on no
  longer holds, the same check should also be able to turn it back off,
  for consistency with the camera-toggle's own framing of this as "K9
  perception," not something to hold onto after ceasing to be a K9 at all.
- `HasK9Access()` (the existing `client/main.lua` global, already
  TTL-cached ~1000ms per `phase2_notes/EXPORT_TRACKING.md`'s Phase 1
  contract table, so this reuses an existing cache rather than adding a
  new server round-trip) has transitioned from `true` to `false` since the
  thread's own last tick → force both off (§6.5). This is a **polling**
  detection, not an event push — accepts up to ~1 second of latency
  between the actual server-side revoke and the client noticing, which is
  an acceptable tradeoff for a one-time UX courtesy per the tension noted
  in §6.5 above, and avoids reopening `server/certifications.lua` (an
  already-reviewed Phase 1 file) to add a new broadcast event just for
  this.
- Thread exits once both effects are off (checked at the top of each
  iteration) — no reason to keep polling once there's nothing left to
  clean up; the next toggle-on restarts it.

**Open question flagged for coder-backend, not decided here:** if ~1s
polling latency for the cert-revoke case turns out to matter in practice
(e.g. QA flags a visibly-stuck effect for a second after being fired), the
alternative is a small, additive change to `server/certifications.lua`'s
two revoke paths (manual revoke, `OnJobUpdate` auto-revoke) — firing a new,
dedicated `TriggerClientEvent('qbx_k9unit:client:k9AccessRevoked', ...)`
broadcast alongside the existing `ox_lib:notify` call, which
`client/vision.lua` (and potentially other Phase 2 modules that want the
same signal) could subscribe to directly for immediate, event-driven
cleanup instead of polling. Not proposed as the default here because it
means touching an already-reviewed Phase 1 file for a Phase 2 concern —
flagging it as the natural escalation path if polling proves insufficient,
not silently deciding it's unnecessary.

---

## 7. Proposed function contract for `client/vision.lua`

Per `phase2_notes/EXPORT_TRACKING.md`'s tracked "open naming slot #1"
(vision toggle function names) and this codebase's established
resource-global naming convention (`ToggleX`/`IsX`, PascalCase,
verb/predicate-first):

- `ToggleThermalVision()` — the `K`-keybind's command handler; internally:
  check `IsOwnModelK9()` (§3), then flip `SetSeethrough`, turning off
  night vision first if it was active (§4), then start the maintenance
  thread (§6) if not already running.
- `ToggleNightVision()` — mirror of the above, `SetNightvision`,
  `J`-keybind.
- `IsThermalVisionActive()` — thin wrapper over `IsSeethroughActive()`
  (§2a) — the native's own getter is the source of truth, not a
  separately-tracked local boolean.
- `IsNightVisionActive()` — thin wrapper over `IsNightvisionActive()`
  (§2b), same reasoning.

No other file currently needs to call into these (§1 confirms no radial
item; no other Phase 2 file's design references vision toggling) — but
exposing them as resource-globals rather than file-local functions still
follows this codebase's established pattern (every existing toggle/action
function is a resource-global, per `phase2_notes/EXPORT_TRACKING.md`'s
Phase 1 contract table) in case a later phase (e.g. a HUD indicator in
Phase 4, or handler-down defense in Phase 3 wanting to force night vision
on for the K9 automatically) wants to call in from outside this file.

---

## 8. Remaining open questions (only what's genuinely still unresolved after §11 landed)

1. **§6's disconnect-equals-resource-stop assumption** — high confidence,
   flagged for verification against real client behavior once code exists
   (§6.3), not something this note can test itself.
2. **§6's polling-vs-event-push tradeoff for cert-revoke detection** —
   proposed as polling for Phase 2's initial landing, flagged for
   coder-backend to reconsider if QA finds the latency noticeable (§6,
   "Open question flagged for coder-backend").
3. **Exact default keybind characters (`K`/`J`)** are already settled by
   §11.2's `Config.Vision` schema — no longer open, unlike this note's
   first draft which left them undecided.
4. Everything else this note's first draft flagged as open (toggle-vs-
   radial UX, `CanShowK9UI()`-vs-`IsOwnModelK9()` gating, mutual
   exclusivity, native names) is now **resolved** by SPEC.md §11 and
   restated as settled fact in §1–§4 above, not re-opened here.
