# Phase 4 early design note: Health/Stamina/Hunger/Thirst HUD (`Config.Features.HealthStaminaHUD`)

Author: coder-frontend (NUI / Lua↔JS bridge lens)
Date: 2026-08-23
Status: **DESIGN NOTE ONLY — no `.lua`/`.html`/`.css`/`.js` implementation
written or intended by this file.** Written working ahead of a detailed
Phase 4 spec, the same way Phase 2's five `phase2_notes/*.md` design pairs
worked ahead of SPEC.md §11 before it existed. Placed in `phase2_notes/`
per explicit direction — this is the resource's general "working ahead of
the detailed spec" notes location regardless of which phase's work it
covers, not a claim that this is actually Phase 2 content.

**Important asymmetry vs. the Phase 2 notes this mirrors:** every Phase 2
design note eventually got reconciled against a same-day, detailed §11
pass from product-agent. As of this writing **no equivalent Phase 4 detail
section exists in SPEC.md** — §6.6 and §8's Phase 4 paragraph are still the
original high-level placeholder bullets, not yet superseded the way §6.3/
§6.4 were. That means more of what follows is genuinely open (not "open
until §11 lands and settles it") than was true even for the *first-draft*
Phase 2 notes. Treat every "OPEN" item below as needing an actual product/
architecture decision before implementation, not just a reconciliation
pass against an already-written detailed spec.

**Scope of this note:** `Config.Features.HealthStaminaHUD` only — the
first bullet of SPEC.md §6.6 (health/stamina/hunger/thirst). §6.6's other
six bullets (fatigue, mood, fear/stress, distraction, injury/limping, K9
medkit, contraband screen effect) are separate `Config.Features` flags
(`FatigueSystem`, `MoodSystem`, `FearStressSystem`, `DistractionSystem`,
`InjuryLimping`, `K9Medkit`, `ContrabandScreenFX`) with their own gameplay
systems and are **not** designed here, though §9 below flags one
forward-compatibility consideration for the NUI page itself given some of
those (fatigue in particular) are stamina-adjacent and might eventually
want to land on the same overlay.

---

## 1. This is the resource's first NUI — what that changes structurally

Phase 1 and Phase 2 (per `phase2_notes/*.md` and SPEC.md §11.3's file plan)
are Lua-only: no `ui_page`, no `files {}` web assets, no `RegisterNUICallback`
or `SendNUIMessage` call exists anywhere in this codebase yet
(`fxmanifest.lua`, `client/*.lua` confirmed clean of both). Two consequences
worth calling out explicitly rather than assuming away:

1. **No existing in-repo convention to copy** for the Lua↔JS bridge shape,
   the NUI-ready handshake, or where web assets should live. Every design
   choice below is proposed fresh, not "matching what client/vision.lua
   already does" the way Phase 2's notes could lean on Phase 1 precedent.
2. **`fxmanifest.lua` needs new entries** (`ui_page`, a `files {}` block) —
   this is explicitly **coder-architect's call** per the team's stated
   division of lenses ("where UI files should live and how `ui_page`/build
   output fit into the resource layout"), not something this note commits
   to unilaterally. §10 below sketches what's needed as a starting proposal
   for that conversation, not a final answer.

---

## 2. Proposed NUI page structure — minimal, vanilla, no framework

**Recommendation: plain HTML/CSS/JS, no Vue/React, no bundler/build step.**
Rationale, flagged as a recommendation for coder-architect/coder-ui to
confirm or override, not asserted as the only valid answer:

- Nothing else in this resource has any JS tooling (no `package.json`, no
  bundler config, anywhere in the repo) — introducing a framework and build
  pipeline for a four-bar readout would be disproportionate machinery
  relative to the actual UI surface being built, and inconsistent with how
  deliberately minimal every other Phase 1/2 piece of this resource has
  stayed (e.g. `client/radial.lua`'s explicit "must never implement...
  logic directly" thin-wiring-only self-constraint).
- The whole feature is a **receive-only, non-interactive overlay** (see §3)
  — there's no form state, routing, or component tree complex enough to
  benefit from a reactive framework. A single `<div>` per bar, updated via
  direct DOM writes (`el.style.width`, `el.textContent`) from one
  `message` event listener, is the entire JS surface.
- If coder-architect's broader plan for this server already standardizes
  NUI tooling across other resources (e.g. every NUI-having resource on
  this server uses Vite/Vue for consistency), that consistency argument
  can reasonably override this recommendation — flagging that tradeoff
  explicitly rather than assuming this resource exists in isolation.

**Proposed file layout** (directory name itself is coder-architect's call —
`web/` used here only as a placeholder):

- `web/index.html` — skeleton: a single root container (`#k9hud`) holding
  four labeled bar elements (health/stamina/hunger/thirst), each a
  track+fill pair (`<div class="bar-track"><div class="bar-fill"></div></div>`)
  plus a numeric readout. No external icon font/library dependency (keeps
  the zero-build-step property — even a small icon library is one more
  asset to vendor) — text labels or simple CSS shapes only.
- `web/style.css` — fixed-position overlay (bottom-left is a reasonable
  default, consistent with where most FiveM HUDs place vitals; exact
  placement is a coder-ui call, not decided here), semi-transparent
  background, CSS `transition` on `width` for smooth bar animation between
  pushes rather than a snap-to-value jump. **Two rules that matter more
  than placement, called out explicitly per this note's focus/input lens:**
  - `#k9hud { pointer-events: none; user-select: none; }` on the root
    container — this HUD must never be able to intercept a mouse click or
    text selection even by accident, since (see §3) no `SetNuiFocus` call
    is ever made for it and it should behave exactly like the game's own
    native minimap/health-in-corner overlays: always visually present when
    applicable, never interactive.
  - Root container defaults to `display: none` (or `visibility: hidden`)
    until the first `k9hud:visibility` push sets it visible (§4) — avoids a
    flash-of-unstyled/default-visible content before Lua ever sends
    anything, which matters more here than in a typical menu NUI page
    since this page is expected to be loaded (via `ui_page`) for the
    *entire client session*, not opened/closed like a modal.
- `web/app.js` — one `window.addEventListener('message', ...)` handler
  dispatching on `event.data.action` (§4's two actions), plus one
  `DOMContentLoaded` handler that fires the ready handshake described in
  §8. No `fetch()` calls back to Lua are needed for this feature's minimal
  scope (see §3) beyond that single handshake callback.

---

## 3. This feature has no player-facing interaction — flag the absence of `RegisterNUICallback` explicitly

Every other NUI feature this team lens document anticipates ("matching
`RegisterNUICallback` handlers to frontend `fetch` calls") assumes a
two-way bridge. **This one, in its Phase 4 §6.6 first-bullet form, is
one-way: Lua → NUI only.** The player never clicks, types, or otherwise
interacts with the HUD itself — it's a passive readout, structurally closer
to the game's own native minimap than to a menu. Concretely:

- **No `RegisterNUICallback` is needed for the HUD's actual function**
  (pushing/displaying values) — only the one-time `hudReady` handshake in
  §8 exists, and that exists purely to solve a load-order race, not to let
  the player do anything.
- **No `SetNuiFocus` call is ever made for this feature.** This is the
  single most important integration point from this lens's stated concern
  ("`SetNuiFocus` paired correctly with open/close so keyboard and mouse
  input reach the UI only when it should, and always has a reliable close
  path back to the game") — the reliable answer here is simpler than usual:
  **there is no open/close focus state to manage at all**, because the page
  never needs to capture input. Calling out explicitly so whoever
  implements this doesn't reflexively add a `SetNuiFocus(true, true)` call
  the way an interactive menu would need — that would be a bug here, not a
  missing feature.
- Flagging this absence explicitly (rather than silently having no
  callback section) because it's atypical enough for this resource's NUI
  work that a reviewer should be able to confirm it was a deliberate
  choice, not an oversight.

---

## 4. `SendNUIMessage` contract (proposed)

Two message actions, both server-of-truth-free in the sense that neither
requires a new server round trip (see §6 for why):

```
{ action = 'k9hud:visibility', visible = boolean }
{ action = 'k9hud:update', health = number, stamina = number, hunger = number, thirst = number }
```

- **`visible`** is pushed explicitly on every transition edge (§7), rather
  than inferred client-side from "updates stopped arriving." An explicit
  message avoids the ambiguity of "did the last stat push just not arrive
  yet" vs. "the HUD was deliberately hidden" — cheap to send, removes a
  whole class of stale-display bugs.
- **All four `update` fields are proposed as already-normalized 0–100
  percentages**, not raw engine units, so the NUI/JS side never needs any
  GTA-native-specific knowledge:
  - `health`: client computes `GetEntityHealth(ped) / GetEntityMaxHealth(ped) * 100`
    before pushing — never push the raw engine value, since default ped
    max health (200) and "dead" threshold (0, not 100) would otherwise
    require the NUI side to know GTA-specific health semantics it has no
    business knowing.
  - `stamina`: candidate native is something in the
    `GetPlayerSprintStaminaRemaining`/`RestorePlayerStamina` family —
    **not independently verified this session**, flagged the same way
    every `phase2_notes/*_natives.md` pairing flags an unverified native
    rather than asserting an exact signature/scale with false confidence.
    Whoever implements this should get a native-verification pass first
    (mirrors `thermal_night_vision_natives.md`'s role for that feature)
    before assuming a specific function name or 0–100-vs-0–1000 scale.
  - `hunger`/`thirst`: proposed source is the **already-live**
    `QBX.PlayerData.metadata.hunger`/`.thirst` client-side global —
    `fxmanifest.lua` already pulls in `@qbx_core/modules/playerdata.lua`
    for exactly this kind of live-updated metadata cache (its own comment:
    "exposes a live-updated global `QBX.PlayerData` client-side cache...
    so client stubs should read from that rather than re-inventing a
    player-data cache"). **This means no new server relay/callback is
    needed for hunger/thirst** — reusing qbx_core's existing survival-needs
    plumbing rather than building a parallel one. Flagged as an assumption
    needing **coder-backend** confirmation, not asserted as verified fact:
    does the target server's qbx_core fork track `metadata.hunger`/
    `.thirst` in the standard 0–100 range for *every* character regardless
    of ped model, including a K9-model persistent character? Nothing in
    SPEC.md §1/§4.5 suggests a K9 character is exempted from the server's
    normal survival-needs system (it's an ordinary persistent character,
    just wearing a dog model), but this hasn't been checked against a live
    install this session — same caveat class as `phase2_notes/
    contraband_search_contract.md`'s ox_inventory export-name caveats.
- **Push cadence:** a single low-frequency thread tick (proposed default
  250–500ms — exact value is a tuning knob, see §10's config proposal),
  **not per-frame**. Additionally propose a delta-check (only push
  `k9hud:update` when at least one of the four values has changed by more
  than a small epsilon since the last push, e.g. 1 point) to avoid pushing
  an identical payload across the IPC boundary and re-triggering DOM writes
  when a stationary, full-health/stamina/hunger/thirst character has
  nothing new to show — directly in line with this lens's stated concern
  about avoiding unnecessary re-renders/polling.

---

## 5. OPEN QUESTION — when should the HUD actually be visible? (flagged per explicit instruction, not guessed)

SPEC.md §6.6's own bullet text: "visible only while a K9 is spawned and
controlled/nearby." This phrasing does not map cleanly onto the corrected,
no-spawn model (SPEC.md §1/§4.5/§9's repeated "REMOVED... do not
resurrect... SpawnK9/DespawnK9" framing) — it reads like leftover language
from the pre-correction draft that §6.6 was never revisited to fix, the
same category of stale wording the top-of-file revision notes call out
elsewhere in SPEC.md. Four candidate readings, laid out without picking one
as final:

**(a) Whenever `CanShowK9UI()` is true** — mirrors the radial menu's exact
gate (certified K9-model player, in a valid department, server-verified
access). Cheapest mental model ("if you can use K9 features, you see the
HUD"), but couples a cosmetic vitals readout to the *departmental
certification* gate, which feels like a mismatch — an uncertified K9-model
player still has a body with real health/stamina/hunger/thirst, certification
or not.

**(b) Whenever `IsOwnModelK9()` is true, regardless of certification** —
mirrors the precedent already set for the camera toggle
(`client/movement.lua`) and, per `phase2_notes/thermal_night_vision.md`
§3, for vision toggles too: "thermal/night vision is presented in SPEC.md
as the K9's own innate perception, not a granted departmental privilege."
Health/stamina/hunger/thirst are arguably in that same "innate to the
character's own body" bucket, not the "granted capability" bucket (radial/
leash/vehicle) — **this note's tentative lean**, for consistency with that
established precedent, but stated as a lean, not a decision.

**(c) Only while near a partnered handler** — a literal reading of
"...and nearby" if "nearby" modifies a handler being nearby rather than the
K9 itself being nearby the local client (which would be nearly tautological
for your own HUD). This would be an unusual design — why would your own
vitals readout depend on another player's proximity? — and seems like the
least likely intended reading, but included because the task instructions
explicitly asked this to be flagged rather than silently dismissed.

**(d) A player-toggleable HUD (keybind), not always-on** — consistent with
the camera/vision-toggle precedent's "player-controlled QoL" framing, but
§6.6 says "displays," not "can be toggled to display" — this may be
over-reading toggleability into a bullet that intends an always-on element
once the gating condition ((a)/(b)/(c)) holds.

**Recommendation:** get an explicit answer from product-agent/team-leader
before implementation, the same way Phase 2's vision-gating question
(`CanShowK9UI()` vs. `IsOwnModelK9()`, `phase2_notes/EXPORT_TRACKING.md`'s
"Outstanding, unresolved" item 3) needed one rather than being guessed
independently by two design notes. This note's lean is (b), but
implementation should not proceed on that lean alone without confirmation.

---

## 6. Integration with `client/main.lua`'s `CanShowK9UI()`/`IsOwnModelK9()` pattern

Whichever answer §5 lands on, the actual gating call must **reuse** one of
the two existing resource-global functions `client/main.lua` already
exposes — never a third, parallel model/access check invented in a new
`client/hud.lua`. This mirrors `client/main.lua`'s own stated rationale for
`CanShowK9UI()` existing as a single combinator in the first place: "the
'how do we combine these' policy lives in exactly one place." Concretely:

- **Proposed new file: `client/hud.lua`** (Phase 4), added to
  `fxmanifest.lua`'s `client_scripts` list alongside the existing four.
- All registration gated behind `if Config.Features.HealthStaminaHUD then ... end`
  at file-load time — satisfies SPEC.md §3's "read at the point of
  activation" hard requirement, mirroring `client/radial.lua`'s per-item
  `Config.Features` gating convention exactly.
- A single low-frequency thread (§4's cadence), started/stopped rather than
  running unconditionally and no-op'ing internally — mirrors the
  "don't run a loop when the feature isn't in use" principle
  `phase2_notes/thermal_night_vision.md` §2c/§6 already established for
  `client/vision.lua`'s proposed maintenance thread. The thread's own tick
  re-evaluates the §5 gate every cycle (not a one-time latch) so losing the
  gate mid-session (job change, model change, cert revoke — whichever
  applies once §5 is resolved) is caught within one tick, same pattern as
  vision's maintenance-thread design.
- On the gate's false→true edge: push `k9hud:visibility {visible=true}`,
  *then* start the per-tick `k9hud:update` pushes. On true→false: push
  `{visible=false}` and stop the tick — an explicit pair of pushes, not
  "just stop sending updates and let the last-known values sit stale
  on-screen."
- No `SetNuiFocus` call anywhere in this file (§3).

---

## 7. Cleanup / exit-path requirements

Structurally parallel to `phase2_notes/thermal_night_vision.md` §6 (a
client-side visual state that needs an explicit "force it off" path on
every exit, not just the normal toggle-off path) — reusing that note's
checklist shape since it's the closest existing precedent in this
codebase, with one important difference in reasoning called out below:

1. **Resource stop** — `onResourceStop` handler (guarded on
   `resourceName == GetCurrentResourceName()`) force-pushes
   `k9hud:visibility {visible=false}`, idempotent/safe even if the HUD was
   never shown this session. Mirrors `client/vehicle.lua`'s existing
   safety-net pattern and the same pattern proposed for `client/vision.lua`.
2. **Disconnect** — same reasoning as `thermal_night_vision.md` §6.3: very
   likely already covered by #1 firing on disconnect (FiveM stops every
   loaded resource, including this one, as part of disconnect), flagged
   with the same "verify once real code exists, not asserted with
   certainty" caveat rather than a confident claim.
3. **Player death** — genuinely different failure mode from vision's death
   handling, worth calling out rather than copying blindly: vision's
   cleanup exists because a *stuck full-screen effect* after death would be
   a visible bug; a HUD showing `health: 0` on death is **not** a bug, it's
   correct information. No special-case needed here beyond the normal tick
   loop continuing to report the true (zero) health value — flagging only
   so nobody reflexively force-hides the HUD on death by copying vision's
   pattern without checking whether it actually applies.
4. **Whichever §5 gate is chosen stops holding mid-session** (job change,
   cert auto-revoke per §4.4, or a model change per SPEC.md §9 item 8) —
   already covered by §6's per-tick re-evaluation, no separate mechanism
   needed.

---

## 8. NUI-ready handshake — new pattern for this codebase, needs a sanity check

Because this is the resource's first NUI page (§1), there is no existing
precedent here for "how does the Lua side know the NUI page's JS has
actually attached its `message` listener before the first
`SendNUIMessage` fires" — a real race if `client/hud.lua`'s thread could
start pushing before the browser has finished loading `app.js`.

**Proposed minimal fix:** one `RegisterNUICallback`,
`qbx_k9unit:nui:hudReady`, fired once from `app.js`'s `DOMContentLoaded`/
`window.onload` (a bodyless `fetch('https://qbx_k9unit/hudReady', {method:'POST', body:'{}'})`
call, the standard ox_lib/FiveM NUI-callback pattern), which `client/hud.lua`
listens for and only starts pushing `k9hud:visibility`/`k9hud:update`
after receiving it (buffering the "should be visible" decision if the gate
already passed before the ready signal arrives, so nothing is silently
dropped on a slow page load).

This is the **first `RegisterNUICallback` this resource would ever
register** — worth a quick sanity-check pass with **ui-bridge** once real
code exists, purely because there's no existing pattern in this repo to
copy from for a Lua↔JS readiness handshake specifically (every existing
convention tracked in `phase2_notes/EXPORT_TRACKING.md` is Lua-to-Lua
only — `qbx_k9unit:server:*`/`qbx_k9unit:client:*` events and callbacks,
nothing NUI-facing).

---

## 9. Proposed naming (fills what would otherwise be open naming slots)

No `phase4_notes/`-scoped tracking doc exists yet (the Phase 2 pattern was
`phase2_notes/EXPORT_TRACKING.md`, owned by api-contract-agent, updated as
each design note landed) — since this is the *first* Phase 4 design note,
there's no collision risk yet, but recommend whoever writes the second one
either extend `EXPORT_TRACKING.md` with a Phase 4 section or start an
equivalent Phase-4-scoped tracking doc before a second Phase 4 note risks
independently inventing a competing name for the same slot (the exact
failure mode `EXPORT_TRACKING.md` documents happening twice in Phase 2:
`StartScentTracking` vs. `StartScentTrack`, and the contraband-search
callback-vs-event-pair mismatch).

Proposed names, for the record:
- `RegisterNUICallback` name: `qbx_k9unit:nui:hudReady` — no payload.
- `SendNUIMessage` actions: `k9hud:visibility` (`{visible: boolean}`),
  `k9hud:update` (`{health, stamina, hunger, thirst: number}`, all 0–100).
  These are NUI message `action` strings, not real FiveM
  events/callbacks, so an exact match to the `qbx_k9unit:server:`/
  `qbx_k9unit:client:` colon convention isn't structurally required the way
  it is for `RegisterNetEvent`/`lib.callback` names — using a short
  `k9hud:` prefix here is a stylistic choice for readability, not an
  enforced pattern, and open to a different convention if coder-frontend/
  coder-ui prefer one once a second NUI feature exists to compare against.
- `client/hud.lua` resource-global: propose `IsK9HudVisible() -> boolean`
  (thin wrapper over the current pushed visibility state) even though
  nothing else needs to call it yet for this Phase 4 bullet alone — mirrors
  `phase2_notes/thermal_night_vision.md` §7's reasoning for exposing
  `IsThermalVisionActive()`/`IsNightVisionActive()` as resource-globals
  "in case a later phase... wants to call in from outside this file" (a
  concrete candidate here: Phase 5's deployable kennel accelerated-healing
  readout, or Phase 4's own fatigue system, might want to know/force a HUD
  refresh later).

---

## 10. `fxmanifest.lua` / config sketch (starting proposal, not a decision)

**fxmanifest.lua** (coder-architect's call on directory/file names — `web/`
used here as a placeholder):
```
ui_page 'web/index.html'
files { 'web/index.html', 'web/style.css', 'web/app.js' }
```
added alongside the existing `client_scripts` entry for the new
`client/hud.lua`. No new `dependencies` entries expected — this page needs
nothing from qbx_core/ox_lib on the JS side for a scope this minimal
(unconfirmed whether ox_lib ships any JS-side component library worth
reusing here; out of scope to chase down for a four-bar readout).

**Config tuning knob** (mirrors the existing pattern of named tuning
constants rather than magic numbers, e.g. `Config.LeashMaxDistance`,
`Config.VehicleInteractMeters`): propose `Config.HudUpdateIntervalMs`
(default suggestion: `500`) for whoever writes the real Phase 4 config
block, living alongside `Config.Features.HealthStaminaHUD`. Not adding this
to `config.lua` directly in this note (no implementation code, per this
note's own status line) — flagging the name/shape for whoever does.

---

## 11. Security note (brief — this feature has an unusually small attack surface)

Because this feature is receive-only (§3 — no NUI→Lua callback other than
the inert `hudReady` handshake, no player-modifiable value ever sent back
to the server), the usual "server must independently validate anything a
callback accepts" standard this team holds every gated action to doesn't
have much surface to apply to here — there's no capability being requested
through this NUI page, only a display. The one thing worth a
**coder-security** sanity check once real code exists, flagged as "confirm,
don't assume" rather than asserted outright: a modified client could fake
its own `k9hud:update` values to show itself a flattering (e.g. 100/100/
100/100) readout on its own screen — confirm this genuinely grants no
gameplay advantage, since (a) health/stamina are reads of the *local*
player's own already-locally-visible state (the base game already shows a
player their own health/stamina via its native HUD elements — this NUI
page adds a K9-specific presentation of the same locally-known values, not
new information), and (b) hunger/thirst mirror qbx_core's existing
client-side-cache-for-display / server-side-authoritative-for-decay
metadata pattern (§4), which the server presumably already trusts this way
for its own existing hunger/thirst-driven mechanics elsewhere (out of this
resource's scope to re-verify qbx_core's own trust boundary here, but worth
naming the assumption explicitly).

---

## 12. Summary of what's OPEN vs. what this note proposes as settled-enough-to-build-on

**Open, needs an explicit decision before implementation (not this note's
call):**
1. §5 — exact visibility gate (`CanShowK9UI()` vs. `IsOwnModelK9()` vs.
   handler-proximity vs. toggleable). Tentative lean: (b) `IsOwnModelK9()`.
2. §4 — exact stamina native/scale (needs a native-verification pass).
3. §4 — whether `metadata.hunger`/`.thirst` genuinely applies uniformly to
   a K9-model character on the target server (needs coder-backend
   confirmation).
4. §1/§2/§10 — file/directory layout, `ui_page` path, framework choice
   (needs coder-architect sign-off; vanilla-JS/no-framework is this note's
   recommendation, not a unilateral decision).

**Proposed and reasonably load-bearing (built on existing, already-shipped
codebase precedent, low risk of needing to change even once the above
settle):**
- No `SetNuiFocus` call ever, for this feature (§3).
- Two-message `SendNUIMessage` contract, normalized 0–100 values (§4).
- Reuse `IsOwnModelK9()`/`CanShowK9UI()` rather than a third check (§6).
- A single start/stop (not always-running) low-frequency thread in a new
  `client/hud.lua`, gated on `Config.Features.HealthStaminaHUD` at
  file-load time (§6).
- Explicit visibility-edge pushes plus a `hudReady` handshake to avoid
  load-order/staleness bugs (§4, §8).
- Cleanup on resource-stop; death is *not* a special case unlike vision's
  precedent (§7).
