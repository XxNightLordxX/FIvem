# qbx_k9unit — Phase 4 Vitality HUD: Lua↔JS Bridge Design

Status: design note only — **no `.lua`/`.js`/`.html` implementation here**.
Scope: the NUI *wiring* for SPEC.md §6.6's first bullet only ("NUI HUD
displays health, stamina, hunger, and thirst for the active K9... only if
`Config.Features.HealthStaminaHUD` is true"). This is the **first NUI
surface this resource has ever had** — no `html/` directory, no
`ui_page`/`files` block in `fxmanifest.lua`, and no `RegisterNUICallback`/
`SendNUIMessage` call anywhere in the codebase today. Everything below is a
proposal, not a reconciliation of an existing contract.

**`phase2_notes/phase4_hud_early_design.md` does not exist yet** (checked
directly — not present in `phase2_notes/`). Per the task's own fallback
instruction, this note proceeds independently of coder-ui's overall
component/UX design and covers **only** the bridge mechanics (naming,
focus, push cadence, data shape). Component layout, styling, exact pixel
placement, and whether/how the HUD visually degrades under
`Config.Features.HealthStaminaHUD = false` at the CSS/markup level are
coder-ui's call, not decided here — coordinate with coder-ui before
building `html/` against this so the two sides don't diverge on the one
thing that must match exactly: the payload shape in §3 below.

> **Update (product-agent, 2026-08-23, reconciliation pass):**
> `phase2_notes/phase4_hud_early_design.md` now does exist and independently
> arrived at a lean toward the same gate this note originally recommended
> (`IsOwnModelK9()`), while leaving it explicitly open. Both notes turned out
> to be reasoning from the wrong precedent — see the corrected §6 below.
> Nothing in §1-§5 or §7 changes as a result: naming, payload shape, focus
> policy, and push cadence are all independent of which local predicate
> ultimately feeds `visible`.

---

## 1. Why this HUD does not fit the Phase 1 naming convention as-is

`EXPORT_TRACKING.md`'s "Naming convention observed" section documents this
codebase's existing pattern: `RegisterNetEvent`/`TriggerServerEvent`/
`TriggerClientEvent` names are `qbx_k9unit:server:<verbNoun>` (client→server)
and `qbx_k9unit:client:<verbNoun>` (server→client) — see `relayBark`/
`playBark`, `requestLeashAttach`/`leashAttachRequest`/`leashAttached`/
`leashDetached`.

That `qbx_k9unit:` prefix exists for a specific reason: FiveM's
`RegisterNetEvent` namespace is **global across every resource on the
server**, so without a resource prefix, `qbx_k9unit`'s `relayBark` could
collide with some unrelated resource's own `relayBark`. **This reason does
not apply to NUI.** Two different mechanisms, two different collision
domains:

- `RegisterNUICallback(name, ...)` names are only ever reached via
  `fetch(\`https://${GetParentResourceName()}/${name}\`, ...)` — the resource
  name is already baked into the URL by `GetParentResourceName()`. Adding a
  second `qbx_k9unit:` prefix on top of that is pure redundancy (the URL
  would read `.../qbx_k9unit/qbx_k9unit:hudReady`), not collision
  protection.
- `SendNUIMessage(...)` payloads are delivered as `message` events inside
  the browser context of `html/index.html`, a page that belongs
  exclusively to this resource. Nothing outside `qbx_k9unit` can send a
  `message` event into that page's own JS, and this page never listens for
  messages meant for any other resource's NUI. There is no shared
  namespace to collide in at all.

**Do not copy the `qbx_k9unit:client:`/`qbx_k9unit:server:` prefix onto NUI
names.** Instead, this note proposes a lighter-weight convention that keeps
the same *flavor* (verb-first, camelCase, colon-separated) the rest of the
codebase already uses for payload keys (`barkType`, `targetServerId`,
`isConstrained`) and resource-global function names (`IsOwnModelK9`,
`RequestLeashAttach`), scoped by **NUI surface**, not by resource:

```
<surface>:<verbNoun>
```

`hud` is the only surface today. If Phase 4's `K9Inventory` stash UI or a
later interactive panel needs its own NUI callbacks, they'd get their own
surface prefix (e.g. `stash:open`) rather than colliding with `hud:*` —
this is future-proofing, not something to build now.

---

## 2. Callback/message names proposed

| Name | Direction | Mechanism | Purpose |
|---|---|---|---|
| `hud:ready` | JS → Lua | `RegisterNUICallback` | Fired once by `html/index.html`'s JS immediately after it attaches its `message` listener. Tells `client/hud.lua` "it is now safe to push, and please send an immediate snapshot" — see §5's race note. `cb({})` fire-and-forget, nothing meaningful to return. |
| `hud:updateVitals` | Lua → JS | `SendNUIMessage({ action = ..., data = ... })` | The one and only ongoing push. See §3 for the exact payload. |

No other callback is needed for this feature as scoped. This HUD has zero
user-driven interaction (no buttons, no dismiss, nothing the player clicks
or types) — see §4 for why that also means no focus/escape handling is
needed, unlike every other piece of UI this codebase has (`lib.alertDialog`
consent prompts, the radial menu). If a future Phase 4/5 feature adds a
clickable element to this same page (unlikely, given it's meant to be a
passive status readout, but flagging in case coder-ui's design note
introduces one), that element needs its own `hud:<verbNoun>` callback and,
separately, its own focus-grab/release pair per §4 — **do not** let a future
click target piggyback on this HUD's currently-focus-free lifecycle without
re-deciding the whole focus question.

---

## 3. Payload shape — one unified message, not split by field

Proposed shape, sent under action `hud:updateVitals`:

```
{
  action = 'hud:updateVitals',
  data = {
    visible = <boolean>,
    health  = <number>,  -- 0-100, normalized percent
    stamina = <number>,  -- 0-100
    hunger  = <number>,  -- 0-100
    thirst  = <number>,  -- 0-100
  }
}
```

**Decision: one combined action carrying both the visibility flag and all
four values, always sent together, over a single split into e.g.
`hud:setVisible` + `hud:updateVitals`.** Rationale, mirroring how
`client/radial.lua`'s header documents its own "option (b) chosen over (a)"
reasoning rather than just asserting a choice:

- A split-message design has two moving parts that can desync if one
  message is ever dropped (see §5's race note on NUI message delivery not
  being queued/guaranteed before the page's listener attaches) — e.g. a
  `setVisible(true)` arrives but the *next* `updateVitals` doesn't land for
  another full heartbeat, leaving the HUD visible with stale/default
  numbers for up to that interval.
- A single message means the JS-side listener has exactly one `case` to
  handle for this whole feature, and `visible` + the four numbers are
  always mutually consistent by construction (same message, same tick).
- The cost is sending four extra numbers on the (rare) frames where only
  visibility flips — negligible; these are small JSON payloads on an
  already-throttled cadence (§5), not a per-frame stream.

JS-side, the listener should treat `data.visible === false` as "hide the
whole HUD root, ignore the numeric fields" rather than trying to render
zeros — Lua still sends the last real known values alongside
`visible = false` (not zeroed out) specifically so that if visibility flips
back to `true` before the next real poll tick, the JS doesn't have to wait
out a stale-zero flash; it already has good numbers sitting in its own
local state from the last true push.

**Source of each value (client-only reads, no server round trip needed for
this feature):**

- `health` — `GetEntityHealth(PlayerPedId())` normalized against
  `GetEntityMaxHealth(PlayerPedId())`. Purely local.
- `stamina` — `GetPlayerSprintStaminaRemaining(PlayerId())`, a real native
  returning 0.0-100.0 directly (HIGH confidence on this native's existence
  and range; standard in the FiveM ecosystem). Purely local.
- `hunger` / `thirst` — expected to read from `QBX.PlayerData.metadata`
  (the live-updated global `@qbx_core/modules/playerdata.lua` already pulls
  into every client script per `fxmanifest.lua`'s own convention note, and
  is the same source `SPEC.md` §6.5 cites for `metadata.k9certified`).
  **MEDIUM confidence only** on the exact field names (`hunger`/`thirst`)
  and 0-100 scale — not verified against `qbx_core`'s actual metadata
  schema this session. Confirm the real field names/scale with whoever owns
  the `qbx_core` integration before wiring the real read; if they don't
  exist under those names, this is a `qbx_core`-side lookup, not a new
  server event in this resource (no need to invent
  `qbx_k9unit:server:getHunger` — reuse the existing live client cache the
  same way `metadata.k9certified` already is reused, don't build a second,
  redundant network path for data the client already has).

**This is a structurally simpler bridge than the leash/cert system**: all
four source values are already known to the client with zero network
latency, so unlike `HasK9Access`/`CheckLeashEligibility`, there is no
server-authoritative check anywhere in this specific bridge and no new
server event is needed for Phase 4a's HUD display itself. (Other §6.6
sub-features — fatigue, mood, fear/stress, injury — may well need real
server state and their own events later; that's out of this note's scope,
which is display-only health/stamina/hunger/thirst per the task's framing.)

---

## 4. Focus policy: `SetNuiFocus` should never be called for this HUD

This is a **passive, always-visible-while-relevant overlay**, not a menu —
the player never clicks into it, types into it, or needs to alt-tab out of
the game to interact with it. Per this agent's own process rule 3
("distinguish HUD-style always-on UI... from interactive menus... don't
grab keyboard focus for passive HUD elements"), the design here is:

- **`client/hud.lua` never calls `SetNuiFocus` at all** — not on
  resource start, not on becoming visible, not anywhere. Compare this to
  `client/movement.lua`'s `lib.alertDialog` leash-consent prompt, which
  *is* a real interactive modal and (via ox_lib's own internal NUI)
  legitimately needs focus while it's up — this HUD has no equivalent
  moment.
- Because focus is never taken, **process rule 4's "handle the
  escape/close path" does not apply here** — there is no way for this
  particular NUI to get "stuck open with focus grabbed" (the entire bug
  class rule 4 exists to catch) because it never grabs focus in the first
  place. No `Escape` keylistener, no close button, no close callback needed
  for this surface. This is a deliberate scope statement, not an
  oversight — flagging it explicitly so a reviewer doesn't file a "missing
  escape handler" bug against a surface that structurally can't have that
  bug.
- **CSS-side gotcha to flag for coder-ui, since it's the other half of
  "focus state consistency" for a *focus-less* HUD**: `SetNuiFocus(false,
  false)` being the permanent state means mouse clicks pass through to the
  game by default — but only if the HUD's own root container doesn't
  accidentally block them. A NUI page's browser surface still paints on
  top of the game and, depending on how `html/index.html`'s CSS is
  written, an element covering screen space **can** intercept clicks even
  with focus disabled, if that element (or an ancestor) doesn't have
  `pointer-events: none` set. This is a real, easy-to-miss bug class for
  exactly this kind of "no focus, but still on-screen" HUD — recommend
  `pointer-events: none` on the HUD's root element (and everything under
  it, since this design has zero interactive children per §2) as a
  hard requirement for `html/index.html`'s CSS, not an optional hardening
  pass.
- Visibility (show/hide, not focus) is driven entirely by the `visible`
  field in `hud:updateVitals`'s payload (§3), toggled client-side via CSS
  (e.g. a class add/remove or `display` toggle) — never via
  `SetNuiFocus`, which controls input routing, not paint/visibility.

---

## 5. Push cadence — throttled, not per-frame

A live per-tick push (`SendNUIMessage` every game frame or even every
server tick) would be wasteful for four slowly-changing numbers nobody
needs sub-second precision on. Proposed design, in the same spirit as this
codebase's existing tick/TTL constants (`HAS_K9_ACCESS_CACHE_TTL_MS = 1000`
in `client/main.lua`; `LEASH_TICK_MS = 250` / `LEASH_IDLE_TICK_MS = 1000`
in `client/movement.lua`):

1. **Poll tick: every ~250ms** while `Config.Features.HealthStaminaHUD` is
   true and the visibility predicate (§6) is true. All four reads are
   local/cheap (no network, no `lib.callback.await`) unlike
   `HasK9Access`'s hot-path concern, so polling this often client-side
   costs nothing meaningful — this is not the same class of cost as
   re-awaiting a server callback every 250ms, and should not be conflated
   with that concern even though the interval looks similar to
   `LEASH_TICK_MS`. **Footnote added after §6's resolution:** the gate
   itself (§6, now `CanShowK9UI()`) *does* call through to `HasK9Access()`,
   which has a real server round trip behind it — but `client/main.lua`'s
   existing `HAS_K9_ACCESS_CACHE_TTL_MS = 1000` debounce means
   re-evaluating `CanShowK9UI()` once per 250ms poll tick triggers at most
   one fresh `lib.callback.await` per second, not one per poll tick — the
   same cache every other `CanShowK9UI()`/`HasK9Access()` call site in this
   codebase (every radial item's `onSelect`, `client/vehicle.lua`'s
   `canInteract`) already relies on for exactly this reason. This does not
   reintroduce the "hot-path callback" cost class this paragraph is
   drawing a distinction against; it's specifically the four vitals reads
   that are unconditionally free regardless of gate, not a claim that
   nothing in the tick ever touches the network.
2. **Only actually call `SendNUIMessage` when something worth repainting
   changed**: compare each of the four values against what was last sent,
   using a small change-threshold (epsilon) per field rather than exact
   equality — e.g. only re-push if any value moved by more than ~0.5 (on
   the 0-100 scale). This absorbs float jitter from
   `GetPlayerSprintStaminaRemaining` and avoids a wasted `SendNUIMessage`
   call (and JS-side re-render) every single poll tick just because
   stamina drifted by 0.01.
3. **Heartbeat ceiling: force a push at least every ~1000ms even if
   nothing changed enough to cross the epsilon**, so (a) a HUD that missed
   an update for any reason (dropped message, page reload mid-session,
   NUI focus/paint hiccup) self-heals within one second rather than
   showing stale numbers indefinitely, and (b) `hud:ready`'s race (below)
   has a bounded worst case even if the immediate-snapshot push in step 5
   is somehow missed.
4. **Idle backoff**: while the visibility predicate (§6) is false (e.g.
   not currently playing a K9-model character), don't poll at 250ms at
   all — drop to a cheap ~1000ms idle check, matching the exact pattern
   `client/movement.lua`'s `AgilityBasicJump` suppression thread already
   uses (`Wait(0)`/tight loop only while actually relevant,
   `Wait(1000)` idle poll otherwise) and `client/movement.lua`'s own leash
   thread (`LEASH_TICK_MS` vs `LEASH_IDLE_TICK_MS`).
5. **Immediate out-of-cycle push on any visibility transition** (true→false
   or false→true), bypassing both the epsilon check and the heartbeat
   wait — hiding/showing the whole HUD is a discrete, rare event (a
   handler mounting/dismounting their K9 character, a feature toggle),
   not continuous noise, and should feel instant rather than waiting up to
   ~250ms-1000ms for the next scheduled tick.
6. **Immediate snapshot on `hud:ready`.** `SendNUIMessage` delivery is not
   queued or retried — a message sent before the NUI page's JS has
   attached its `message` listener is simply lost, not buffered. Without
   `hud:ready`, a player who just spawned/loaded in would see nothing (or
   a blank/default-styled HUD) until the next scheduled heartbeat tick
   (§5.3's ~1000ms ceiling bounds this, but there's no reason to accept
   even that short a gap when a one-line ack callback removes it
   entirely). `client/hud.lua`'s `RegisterNUICallback('hud:ready', ...)`
   handler should immediately compute and push one `hud:updateVitals`
   message the moment it fires, independent of the regular poll-tick
   schedule.

None of the above needs a config addition — these are implementation
constants local to `client/hud.lua`, the same way `LEASH_PULL_ZONE_FACTOR`/
`LEASH_HARD_CAP_FACTOR` are file-local tuning knobs rather than
`Config.*` entries.

---

## 6. Visibility predicate — RESOLVED: `CanShowK9UI()`, not `IsOwnModelK9()` alone

> **Correction (product-agent, 2026-08-23, reconciliation pass):** this
> section originally recommended gating "controlled" on `IsOwnModelK9()`
> alone, reasoning by analogy to `ToggleK9Camera()`/thermal-night-vision's
> settled precedent (§11.5: "innate perception, not a granted departmental
> privilege"). That analogy does not hold for this feature — the
> resolution below reverses that recommendation. Nothing about naming,
> payload shape (§2-§3), focus policy (§4), or push cadence (§5, aside from
> the footnote added there) changes as a result; only the boolean that
> feeds `visible` changes.

SPEC.md §6.6's exact wording: "visible only while a K9 is spawned and
controlled/nearby, and only if `Config.Features.HealthStaminaHUD` is true."
This note originally treated "controlled" as unambiguous and mapped it
straight to `IsOwnModelK9()`. It isn't unambiguous, and SPEC.md already
settles it elsewhere — a cross-reference this note missed on first draft:

- **SPEC.md §6.1's own Phase 1 acceptance criterion** (the "Core Systems &
  Controls" group, not §6.6) already states: "A player whose character is
  a K9 ... whose job is in `Config.Departments`, and who holds an active
  certification for that job (§4) sees K9-specific UI (**radial menu, HUD
  once Phase 4 lands**); an uncertified K9-model player or a certified
  player whose job isn't in `Config.Departments` does not." That sentence
  puts the vitality HUD in the **same clause, gated the same way**, as the
  radial menu (Bark/Sit/Leash/Vehicle) — which is unambiguously
  `CanShowK9UI()`-gated, never `IsOwnModelK9()`-only. This is a standing,
  already-checkable acceptance criterion, not a new call being made in
  this reconciliation pass.
- **Applying §11.5's own "innate perception vs. granted privilege" test,
  landing the other way this time:** thermal/night vision is the K9's own
  sense organs — any player wearing the model perceives heat/darkness
  regardless of whether they're on-duty, certified, or even employed by a
  department at all; gating it on certification would mean denying someone
  their own eyesight, which is why §11.5 landed on `IsOwnModelK9()` alone.
  The vitality HUD is not perception, it's a **department-issued
  monitoring instrument** — §6.6 groups it with the XP/progression system
  (§6.5's `speedMultiplier`/`scentRange` tiers) and the mood/fatigue/
  fear-stress systems, all framed around a K9's *working* status for a
  department, not its bare biological existence. An uncertified player who
  happens to be wearing a K9 model (or one whose job just left the
  department) has no in-fiction standing to see an official department
  vitals readout, for the same reason they don't get the radial menu's
  Leash/Vehicle actions either.
- **Practical consequence:** `client/hud.lua`'s gate is `CanShowK9UI()`
  (the existing combinator in `client/main.lua`, already used by every
  radial item's `onSelect` re-check), evaluated on the same per-tick
  cadence §5 already describes — see §5 point 1's added footnote for why
  this doesn't reintroduce a server-hot-path cost.

**"...or nearby" remains genuinely open, not resolved by this pass**: it
could mean a handler/officer partner sees *their K9's* vitals while
nearby/leashed to them, which `CanShowK9UI()` alone (evaluated against the
*local* player) cannot satisfy on its own — that would still need the
payload to identify *whose* vitals are being shown (e.g. an added
`subjectNetId`/`isSelf` field) and a second local predicate reusing
`IsLeashed()`'s existing state from `client/movement.lua` rather than
inventing new leash-adjacent state. **Flagged for coder-ui/coder-architect
to resolve, not decided here** — the bridge mechanics above (message shape,
throttle, focus policy) work identically either way; only the local
boolean/predicate feeding `visible` and the identity of whose numbers get
read in §3 would change. Do not block wiring `client/hud.lua`'s own
self-vitals case (now unambiguously `CanShowK9UI()`-gated) on this question
being resolved — ship "controlled" first, extend to "nearby" as an
additive, non-breaking payload field later if that's confirmed in scope.

- **Ecosystem overlap, flagged not resolved**: most Qbox/QBCore servers
  already run a separate core HUD resource showing the *human* character's
  own hunger/thirst/health/armor persistently on screen. Since hunger/
  thirst here are read from the same `QBX.PlayerData.metadata` values that
  hud resource likely also reads, a K9-model character will, under the
  naive design above, show **two** overlapping hunger/thirst readouts at
  once (the server's existing core HUD, plus this one) unless the server's
  core HUD is itself configured to suppress while the player is
  K9-modeled, or this HUD's placement/styling is deliberately
  differentiated. Purely a UX/layout call for coder-ui, not a bridge
  concern — flagging so it isn't discovered for the first time during a QA
  pass.

---

## 7. Where this lives / manifest wiring needed

Not implementation code, just the structural additions Phase 4
implementation will need, for whoever picks this up:

- New file `client/hud.lua`, added to `fxmanifest.lua`'s `client_scripts`
  list — owns the poll/push thread (§5), the `hud:ready` callback (§2),
  and reads `Config.Features.HealthStaminaHUD` directly (mirrors every
  other file's existing feature-flag-gating convention, e.g.
  `client/radial.lua`'s `if Config.Features.BasicBarkSounds then`,
  `client/movement.lua`'s `if not Config.Features.AgilityBasicJump then`).
- New `html/` directory (owned by coder-ui) with at minimum an
  `index.html` — `fxmanifest.lua` needs a `ui_page 'html/index.html'`
  entry and a `files { 'html/index.html', 'html/**' }`-style block (exact
  glob depends on the framework/bundler coder-ui picks, e.g. a Vue/React
  build output directory) — neither exists in `fxmanifest.lua` today since
  this is the first NUI in the resource.
- No new `Config.*` field needed beyond the already-existing
  `Config.Features.HealthStaminaHUD` (already present, currently `false`,
  in `config.lua`'s Phase 4 block) — the throttle constants (§5) and the
  visibility predicate (§6) are code-local, not config-driven, matching
  how `LEASH_TICK_MS`/`LEASH_PULL_ZONE_FACTOR` are handled today.

---

## 8. Open items for other agents

- **coder-ui** — confirm/replace this note's payload shape (§3) against
  whatever `phase4_hud_early_design.md` ends up containing once it exists;
  the self-visibility gate is now resolved (`CanShowK9UI()`, §6) — only
  the "nearby"/partner-visibility scope and the core-HUD overlap question
  remain open; confirm `pointer-events: none` gets applied in `html/`'s CSS
  (§4) — this is the one item here with a real, easy-to-miss failure mode
  if skipped.
- **coder-architect** — confirm the `hunger`/`thirst` metadata field names
  and scale (§3) against `qbx_core`'s real metadata schema; sign off on
  `fxmanifest.lua`'s new `ui_page`/`files` block shape once `html/`'s
  actual build output structure is known.
- **coder-security** — this bridge introduces zero new server-authoritative
  surface (§3's "no server round trip needed" note) — nothing here should
  need a security pass on its own, but worth a confirming glance given this
  resource's general policy of looping coder-security in on anything
  NUI-adjacent, in case a later revision of this note adds the
  partner-visibility field from §6 and that turns out to need a
  server-side check after all (e.g. "am I actually leashed to this netId"
  re-validation, if the partner-HUD case is ever built the client could
  otherwise be told to trust its own unverified `IsLeashed()` state for
  something more than cosmetic display).
- **integration-verifier** — once `client/hud.lua` and `html/` exist, verify
  `hud:ready`/`hud:updateVitals` are spelled identically on both sides
  (this is exactly the "callback name mismatch" failure class this agent's
  own process explicitly exists to prevent), that `client/hud.lua`'s gate
  is actually `CanShowK9UI()` per §6's resolution (not a regression back to
  `IsOwnModelK9()` alone), and that no `SetNuiFocus` call was accidentally
  added anywhere in `client/hud.lua`.
