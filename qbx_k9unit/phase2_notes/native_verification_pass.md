# Native verification pass — NetworkRequestControlOfEntity success-check, three ped natives' server status, stamina semantics, cross-file native-context sweep, prop_doghouse_01

Status: pure verification pass, no code touched (only `.lua` files may be edited
this session, and this task is scoped to reading + reporting only). Ordered by
the task's own stated priority. Every claim below is graded HIGH / MEDIUM /
LOW / UNRESOLVED — do not upgrade a grade when reusing this note.

**Network note:** `docs.fivem.net`, `runtime.fivem.net`, `forum.cfx.re`,
`forge.plebmasters.de`, `www.gta5-mods.com`, `wiki.rage.mp`, `gta.fandom.com`,
`static.cfx.re`, `gta-objects.xyz` (DNS timeout), and `www.var-fivem.com` were
all unreachable this session (egress-blocked or timed out). `github.com` and
`raw.githubusercontent.com` were reachable and are the source for every
"confirmed" claim below. Where a blocked site's content is cited anyway, it is
explicitly marked as a **search-index-snippet** citation (the same
one-notch-removed technique this resource's own prior `phase2_notes/*.md`
files already used for `forge.plebmasters.de`), never presented as a direct
fetch.

---

## 1. `NetworkRequestControlOfEntity` success-check — RESOLVED, real fix available

**This is the highest-value finding in this pass.** `client/combat.lua`'s
header currently states: *"this codebase has NO confirmed
`NetworkHasControlOfEntity`-style success check to gate on (not found in this
resource's own native-verification notes)."* That statement is now out of
date.

- **`NETWORK_HAS_CONTROL_OF_ENTITY` is a real, confirmed native.**
  Confirmed by direct fetch of
  `raw.githubusercontent.com/citizenfx/natives/master/NETWORK/NetworkHasControlOfEntity.md`,
  contrasted against a genuine 404 on a nearby, definitely-nonexistent file
  (`NetworkGetEntityOwner.md`) to rule out a hallucinated/reconstructed page —
  the two requests returned distinguishably different results, which is the
  actual verification, not just an unverified prose claim from the fetch tool.
  Raw content, verbatim:
  ```
  ---
  ns: NETWORK
  ---
  ## NETWORK_HAS_CONTROL_OF_ENTITY

  // 0x01BF60A500E28887 0x005FD797
  BOOL NETWORK_HAS_CONTROL_OF_ENTITY(Entity entity);
  ```
  **Confidence: HIGH** (primary source, existence contrast-tested).

- **Confirmed real-world idiom**, independently corroborated by a live
  community client script (`gauthierjcm/menu_props/client.lua`-class result
  surfaced via search) and this resource's own already-cited
  `citizenfx/fivem` issue #3338 discussion thread, both converging on the same
  shape:
  ```lua
  NetworkRequestControlOfEntity(entity)
  while not NetworkHasControlOfEntity(entity) do
      Wait(0)
  end
  ```
  **Confidence: HIGH** that `NetworkHasControlOfEntity(entity)` is the correct,
  real way to check whether a prior `NetworkRequestControlOfEntity` call
  actually succeeded.

- **But do NOT adopt the blocking `while` loop verbatim in this codebase.**
  `citizenfx/fivem` issue #3338 (fetched directly, github.com) documents a
  real, **permanent** failure mode: when an entity's current owner has gone
  out of streaming range and no longer has the entity loaded either, control
  can never be transferred at all — "when trying to use
  `NetworkRequestControlOfEntity` to manually transfer the entity ownership,
  it obviously fails, as the current owner is not aware of the entity," with
  no documented recovery. A `while not NetworkHasControlOfEntity(...) do
  Wait(0) end` loop against a genuinely-stuck entity would **hang that
  iteration of `client/combat.lua`'s shared maintenance thread forever**,
  freezing bite-hold's `DisableControlAction` reassertion, the drag
  `AttachEntityToEntity` reassertion, and every other state that same
  `CreateThread` loop drives — precisely the "unbounded trap" class of bug
  this codebase's own guardrails (PHASE3_SPEC.md §12.0 item 4, restated
  throughout `server/combat.lua`'s header) already treat as unacceptable
  elsewhere.

  **Recommendation for whoever next edits `client/combat.lua`:** call
  `NetworkRequestControlOfEntity(entity)` as today, then check
  `NetworkHasControlOfEntity(entity)` **once** (non-blocking, same tick or
  next), and use the result only to make the existing best-effort disclosure
  honest/informative (e.g. log once if control was never observed after a
  bounded number of maintenance ticks) — never as a blocking gate, and never
  as a condition for whether the effect native itself is called (that would
  reintroduce a different problem: guardrail 3 already requires no
  server-authoritative consequence hinge on a Category B effect's client-side
  success, and the same "never gate on it" spirit should extend to the
  client's own other maintenance work in that shared thread). This upgrades
  `.luacheckrc`'s and `client/combat.lua`'s "no success-check native exists"
  disclaimer from **true-but-now-stale** to **a real, bounded check is
  available and should be used non-blockingly.**

---

## 2. The three ped natives' server-side status — STILL UNRESOLVED, but the prior verification *method* is now shown to be invalid (important correction)

`SetPedFleeAttributes`, `SetBlockingOfNonTemporaryEvents`, and
`SetPedToRagdollWithFall`'s server-side callability remains **genuinely
unconfirmed either way** — no new evidence, positive or negative, was found
this session. The codebase's current posture (relay all three, plus
`SetEntityCanBeDamaged`, to the requesting K9's own client rather than assert
an unverified server-side legitimacy) **remains the correct, honest choice**
and should not change.

However, a real methodological problem in how the *one* native in this saga
that WAS called "confirmed" (`SetEntityCanBeDamaged`, client-only) got that
label is worth flagging, since it undermines reusing the same method on
these three:

- `phase2_notes/phase3_combat_natives.md` and `server/combat.lua`'s own header
  both justify `SetEntityCanBeDamaged`'s client-only conclusion as **"no
  `apiset` entry in the primary source"** (i.e. the `citizenfx/natives` `.md`
  doc's YAML frontmatter).
- I directly tested this signal by fetching the raw frontmatter of
  `ENTITY/SetEntityCanBeDamaged.md` **and** `ENTITY/GetEntityCoords.md`
  (`GetEntityCoords` is definitely, unambiguously server-callable — this exact
  codebase calls it server-side dozens of times, e.g.
  `server/combat.lua`'s `ValidateCombatRequest`). **Both files have
  byte-for-byte identical frontmatter** (`ns: ENTITY`, nothing else — no
  `apiset` key at all, for either). I additionally confirmed
  `PED/SetPedFleeAttributes.md`, `PED/SetBlockingOfNonTemporaryEvents.md`, and
  `PED/SetPedToRagdollWithFall.md` all have the same bare `ns: PED`-only
  frontmatter, no `apiset` field.
  **Conclusion: "apiset presence/absence in the `citizenfx/natives` `.md`
  frontmatter" is not a real signal for ANY of these natives — it doesn't
  distinguish a known-both-sides native from a known-client-only one, because
  neither carries that field in this doc source at all.** This is a genuine
  correction to record, not a nitpick: if this method is reused on a future
  native, it will produce a false "no apiset entry = client-only" verdict on
  natives that are actually server-callable (as it would have for
  `GetEntityCoords` itself).
- `SetEntityCanBeDamaged`'s client-only conclusion still stands, but on
  **different, valid grounds**: a `WebSearch` query surfaced an
  actually-crawled snippet of the (directly-blocked) `docs.fivem.net` page
  for this native explicitly stating *"this native is part of the 'client'
  API set"* — a genuine site-badge citation via search-index snippet, the
  same one-notch-removed technique this resource's own prior notes already
  accept for other blocked sites. **Confidence: MEDIUM-HIGH** (search-index
  snippet of the actual docs.fivem.net badge, not a direct fetch, but a
  specific and unambiguous quote, not an inference).
- I attempted the identical search-snippet technique against
  `SetPedFleeAttributes`, `SetBlockingOfNonTemporaryEvents`, and
  `SetPedToRagdollWithFall`. It did not produce equivalent clean results:
  one query returned only vague, non-committal paraphrase text with no
  quoted badge; another ostensibly matched the queried hash
  (`0x9F8AA94D6D97DBF4`) to a **different, unrelated native name**
  (`IsVehicleStoppedAtTrafficLights`) in a way that contradicts this session's
  own direct primary-source fetch of that exact hash under
  `SetBlockingOfNonTemporaryEvents.md` — i.e. the search-snippet channel
  produced an internally-inconsistent result for this hash and should not be
  trusted for it. **I am explicitly not fabricating a verdict from noisy
  search paraphrase.**

**Verdict: no change to the three natives' status — still UNRESOLVED, exactly
as `client/combat.lua`/`server/combat.lua`/`.luacheckrc` already disclose.**
The disclosed uncertainty in the code is correctly calibrated; only the
citation for the ONE native that was called "settled" deserves a footnote
correction (cite the docs.fivem.net search-index badge snippet, not "apiset
absence in the natives repo," which is not actually a working test).

---

## 3. `GetPlayerSprintStaminaRemaining` semantics — CONFLICTING EVIDENCE, reported honestly rather than resolved

`client/hud.lua` computes displayed stamina as `100.0 - GetPlayerSprintStaminaRemaining(PlayerId())`, on the theory the native tracks exertion (rising toward 100 as the K9 tires), not stamina remaining despite its name.

Two real sources disagree:

- **Against the inversion (native reads as its name suggests, decreasing with use):** the official `citizenfx/fivem` C# client wrapper
  (`code/client/clrcore/External/Player.cs`, fetched directly) wraps this
  native as:
  ```csharp
  /// <summary>
  /// Gets how much sprint stamina this <see cref="Player"/> currently has.
  /// </summary>
  public float RemainingSprintStamina
  {
      get { return API.GetPlayerSprintStaminaRemaining(Handle); }
  }
  ```
  This is part of the actual CitizenFX open-source client, not a third-party
  guess — but the doc comment reads as a plain restatement of the native's own
  name, not language that signals independently-tested runtime behavior.
  **Confidence this reflects tested behavior: LOW-MEDIUM** — it's real source,
  but it is exactly the shape of comment that gets written by whoever
  auto-generates/hand-writes a wrapper property from a native name, without
  necessarily verifying direction empirically.

- **For the inversion (native behaves like rising exertion):** independently
  re-confirmed this session (not just cited from the existing code comment) —
  a `WebSearch` across GitHub surfaced the identical
  `100 - GetPlayerSprintStaminaRemaining(...)` transform in **at least nine**
  separately-authored, actively-maintained FiveM HUD/status resources
  (`status-hud`, `ps-hud`, `qz-hud`, `apx_hud`, `esx_status_stamina_bar`,
  `mp_hud`, `uz_PureHud`, `ns-fortnitehud`, `lj-hud-1`, `fivem-hud`), spanning
  different authors and eras. A backwards stamina bar (filling as you sprint,
  draining at rest) is an immediately, trivially visible bug on first test —
  it strains belief that this many independent maintainers would all
  introduce and never notice/fix the identical directional error.
  **Confidence: MEDIUM-HIGH** on convention/practical grounds, though this is
  breadth-of-agreement corroboration, not a single authoritative
  behavioral test.

- I could not reach a genuinely decisive primary source (an actual in-engine
  test, or a non-blocked forum thread with someone's tested report) — the one
  Cfx forum thread that looked most promising
  (`forum.cfx.re/t/player-stamina/4488661`) is on the blocked-domain list, and
  the search-engine paraphrase of it was internally inconsistent (one clause
  reads as supporting the non-inverted reading, another clause reads as
  supporting the inverted one), so I am **not** citing it as evidence for
  either side.

**Verdict: UNRESOLVED as a clean single-source fact, but the current code's
choice (the inversion) is the better-supported side on the balance of
evidence available this session**, given the number and independence of the
corroborating sources versus the single, likely-name-derived C# doc comment.
Do not treat this as fully closed — the honest next step is a live in-engine
print of the raw value while standing still vs. sprinting, which no sandbox
tool here can perform.

---

## 4. Cross-file native-context sweep (client vs. server) — no new `SetEntityCanBeDamaged`-class bug found

Read in full: `server/partnership.lua`, `client/partnership.lua`,
`server/kennel.lua`, `client/kennel.lua`, `server/wellbeing.lua`,
`client/wellbeing.lua`, plus the already-covered `server/combat.lua` /
`client/combat.lua`.

- **`server/partnership.lua` / `client/partnership.lua`:** every native
  called server-side (`GetPlayerPed`, `GetEntityCoords`, `GetEntityModel`,
  `GetGameTimer`, `GetPlayers`) is already independently
  well-established as server-callable elsewhere in this exact codebase (used
  server-side throughout `server/combat.lua`, `server/main.lua`,
  `server/certifications.lua` already). Client-side natives
  (`NetworkGetPlayerIndexFromPed`, `GetEntityModel`, `GetHashKey`) are
  standard client-safe reads. **No context-mismatch found.**
- **`server/wellbeing.lua` / `client/wellbeing.lua`:** same pattern —
  server-side reads are all `GetPlayerPed`/`GetEntityCoords`/`GetGameTimer`/
  `GetPlayers`-class (already established server-safe in this codebase);
  `client/wellbeing.lua`'s `DisableControlAction` (a per-frame, client-only
  input-suppression native) is correctly confined to client code, mirroring
  `client/movement.lua`'s own established `AgilityBasicJump` use of the same
  native. **No context-mismatch found.**
- **`server/kennel.lua` / `client/kennel.lua`:** the object-creation/
  model-loading natives (`CreateObject`, `RequestModel`, `HasModelLoaded`,
  `SetModelAsNoLongerNeeded`, `IsModelValid`, `PlaceObjectOnGroundProperly`,
  `FreezeEntityPosition`) are all correctly confined to `client/kennel.lua`
  only — `server/kennel.lua` never calls any of them, consistent with the
  file's own header's "WHY THE SERVER COMPUTES THE PLACEMENT COORDS" design.
  **No context-mismatch found**, but one native deserved a closer look given
  the task's framing:
  - `server/kennel.lua`'s `RemoveKennelForCitizenid` calls `DeleteEntity`
    **server-side** directly (with a client-broadcast backstop, and the
    file's own header already discloses this as "medium-high confidence...
    NOT independently re-verified... this session"). I looked at this
    specifically because it is the same *shape* of risk as the
    `SetEntityCanBeDamaged` incident (a server-side call to a native whose
    server availability is assumed, not proven). Findings:
    - No apiset-style signal available (same limitation as section 2 above).
    - Found a real, dedicated Cfx forum tutorial title
      ("`[How-To] Delete entities and vehicles from server-side`",
      search-index title only, page itself blocked) plus widespread anecdotal
      confirmation that server-side vehicle/object deletion is a long-standing,
      ubiquitous convention (impound/garage scripts across the ecosystem).
    - One counter-signal: a real, live GitHub repo
      (`Shrimpey/FiveM-Delete-Vehicles`) that superficially looks like a
      server-side deletion script actually **relays deletion to the client**
      (`TriggerClientEvent('vehiclesDestructor', ...)`) rather than calling
      `DeleteEntity` directly server-side — the same defensive shape
      `server/kennel.lua` itself already uses as a backstop. This is weak
      circumstantial evidence that direct server-side `DeleteEntity` is not
      universally trusted in the wild either, though it does not prove it
      fails.
    - **Verdict: no escalation warranted.** `DeleteEntity` operates on an
      entity's core existence/lifecycle, which (unlike
      `SetEntityCanBeDamaged`'s pure client-rendering/damage-pipeline toggle)
      is represented in OneSync's own server-tracked entity state — a
      meaningfully different category of native, and one this codebase's own
      belt-and-suspenders design (direct server call + broadcast backstop)
      already treats correctly as "probably fine, but don't rely on it
      alone." I found nothing to raise or lower `server/kennel.lua`'s own
      existing confidence grading — flagging that I checked, not that I found
      a new bug.
- **`server/combat.lua` / `client/combat.lua`:** already covered exhaustively
  in the existing `phase2_notes/phase3_combat_natives.md` and this session's
  sections 1-2 above; no additional context-mismatch found beyond what is
  already disclosed there.

**No second `SetEntityCanBeDamaged`-class bug (a native silently called in a
context it doesn't support) was found in any of the eight files read for this
sweep.**

---

## 5. `prop_doghouse_01` — still UNCONFIRMED; documented fallback remains the right call

Could not confirm `prop_doghouse_01` as a real vanilla GTA V object model
name from any reachable source this session. What was found:

- `docs.fivem.net`, `forge.plebmasters.de`, `www.gta5-mods.com`,
  `gta.fandom.com`, and `www.var-fivem.com` (all plausible sources for a
  prop-name lookup) were all blocked this session.
- `gta-objects.xyz/objects/prop_doghouse_01` — a `WebSearch` result surfaced
  what looks like a dedicated per-object database page at exactly this URL,
  which is modest circumstantial positive evidence (such per-object database
  sites are typically generated from a full decompiled asset list, so a
  clean, specific URL existing is suggestive) — but the host itself timed out
  (`ETIMEOUT`) on direct fetch, so **I could not verify what that page
  actually contains**, or rule out it being an auto-generated "no data" page
  for an arbitrary queried string. Not counted as confirmation.
  **Confidence: essentially UNRESOLVED, marginal positive lead only.**
- A real, dedicated Cfx forum thread titled `[PROPS] Dog house` (search-index
  title only) and a `gta5-mods.com` "Personal Dog" script description
  mentioning "dog kennels" both surfaced — these describe **custom/addon**
  props being shared as separate downloads, which is weak circumstantial
  evidence pointing the *other* way (people share custom doghouse prop packs
  precisely because a good-looking vanilla one may not exist or isn't
  satisfactory) — but this is not proof either; addon packs get shared for
  reasons other than "the vanilla asset doesn't exist" (e.g. wanting a nicer
  one).
- I could not find any technical/model-ID confirmation of Chop's own
  in-fiction doghouse prop name (Franklin's backyard, story mode) through any
  reachable source.

**Verdict: exactly as `config.lua`'s own comment already states — single,
unconfirmed lead, no new confirmation or refutation found this session.**
This is the third documented pass (across this codebase's own prior notes and
this one) that has tried and failed to independently verify this specific
prop name from reachable sources. The existing `fallbackPropModel =
'prop_tennis_ball'` design (a definitely-real, safe placeholder) remains the
correct mitigation — do not remove it, and do not silently upgrade
`propModel`'s confidence rating based on this pass.

---

## Summary table

| Item | Verdict this pass | Confidence | Actionable? |
|---|---|---|---|
| `NetworkRequestControlOfEntity` success-check | **Resolved** — `NetworkHasControlOfEntity` is real and confirmed | HIGH (native exists); HIGH (idiom); but blocking-loop usage is unsafe here (issue #3338) | **Yes** — `client/combat.lua`/`.luacheckrc` disclaimers are now stale; a real, non-blocking check can replace the "no check exists" framing |
| `SetPedFleeAttributes` server-side status | Unresolved (unchanged) | — | No new action; keep client-relay design |
| `SetBlockingOfNonTemporaryEvents` server-side status | Unresolved (unchanged) | — | No new action; keep client-relay design |
| `SetPedToRagdollWithFall` server-side status | Unresolved (unchanged) | — | No new action; keep client-relay design |
| "apiset absence" as a verification method | **Shown invalid** (identical frontmatter on a known-both-sides native and the known-client-only one) | HIGH (directly tested) | Yes — footnote correction only, not a behavior change |
| `SetEntityCanBeDamaged` = client-only | Still holds, via a different (valid) citation | MEDIUM-HIGH (search-index badge snippet) | Footnote correction only |
| `GetPlayerSprintStaminaRemaining` inversion | Conflicting evidence; current code's choice is better-supported on balance | LOW-MEDIUM against / MEDIUM-HIGH for | No change recommended; flag as still open, needs live in-engine test to fully close |
| Cross-file client/server native sweep (8 files) | No new context-mismatch bug found | — | None found to fix |
| `server/kennel.lua`'s server-side `DeleteEntity` | Existing confidence grading unchanged, no escalation | MEDIUM (ecosystem convention) | None — file's own disclosure already correct |
| `prop_doghouse_01` | Still unconfirmed (3rd failed pass) | UNRESOLVED | None — keep fallback |

---

## Sources

Direct fetch (github.com / raw.githubusercontent.com):
- https://raw.githubusercontent.com/citizenfx/natives/master/NETWORK/NetworkRequestControlOfEntity.md
- https://raw.githubusercontent.com/citizenfx/natives/master/NETWORK/NetworkHasControlOfEntity.md (confirmed real, contrast-tested against a genuine 404 on `NetworkGetEntityOwner.md`)
- https://raw.githubusercontent.com/citizenfx/natives/master/PED/SetPedFleeAttributes.md
- https://raw.githubusercontent.com/citizenfx/natives/master/PED/SetBlockingOfNonTemporaryEvents.md
- https://raw.githubusercontent.com/citizenfx/natives/master/PED/SetPedToRagdollWithFall.md
- https://raw.githubusercontent.com/citizenfx/natives/master/ENTITY/SetEntityCanBeDamaged.md
- https://raw.githubusercontent.com/citizenfx/natives/master/ENTITY/GetEntityCoords.md (control case for the apiset-absence test)
- https://raw.githubusercontent.com/citizenfx/natives/master/ENTITY/DeleteEntity.md
- https://raw.githubusercontent.com/citizenfx/fivem/master/code/client/clrcore/External/Player.cs (`RemainingSprintStamina` wrapper)
- https://raw.githubusercontent.com/citizenfx/fivem/master/code/client/clrcore/External/Entity.cs (checked for a control-check wrapper; none found)
- https://github.com/citizenfx/fivem/issues/3338 (NetworkRequestControlOfEntity permanent-failure mode; already cited elsewhere in this codebase, re-confirmed directly this session)
- https://raw.githubusercontent.com/Shrimpey/FiveM-Delete-Vehicles/master/server.lua

Search-index snippets only (site itself blocked; cited as such, not as a direct fetch):
- docs.fivem.net's `SET_ENTITY_CAN_BE_DAMAGED` page (badge text "client API set")
- docs.fivem.net's `SET_PED_FLEE_ATTRIBUTES`/`SET_BLOCKING_OF_NON_TEMPORARY_EVENTS` pages (inconclusive/inconsistent — NOT relied on)
- Cfx forum thread titles: "Player stamina", "[How-To] Delete entities and vehicles from server-side", "[PROPS] Dog house" (titles/existence only)
- gta-objects.xyz `prop_doghouse_01` page existence (URL surfaced via search; page itself unreachable — NOT counted as confirmation)

Unreachable this session (attempted, blocked or timed out): `docs.fivem.net`,
`runtime.fivem.net`, `forum.cfx.re`, `forge.plebmasters.de`,
`www.gta5-mods.com`, `wiki.rage.mp`, `gta.fandom.com`, `static.cfx.re`,
`gta-objects.xyz` (DNS timeout), `www.var-fivem.com`.
