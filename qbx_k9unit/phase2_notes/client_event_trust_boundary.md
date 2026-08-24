# `client/combat.lua` self-triggering trust boundary — design assessment

Author: coder-security, design-only pass (94fbc4e baseline, branch
`claude/code-improver-subagent-qlt3bn`). Read-only against every `.lua` file
this wave; this document is the deliverable, no code was changed.

Scope: the gap 94fbc4e's own comments explicitly left open — "once at least
one [`Config.Features`] flag IS true — none of the handlers below
independently re-verify that a given `applyBiteHold`/`forceRagdoll`/
`applyDragSpeedLimit`/`applyNpcBiteHold`/`applyNpcTakedown`/`dragStarted`
invocation genuinely came from the server rather than a local self-trigger."
This is a **different, narrower question** than `PHASE3_SPEC.md` §12.0 item
8 (whether a legitimately-targeted player can *ignore* an effect the server
genuinely sent them). Read both sections below together — they resolve to
different verdicts for a reason, and conflating them would misstate the
actual posture of this file.

---

## 1. Is "did this genuinely come from the server" answerable at all?

**Short answer: yes, for the specific threat this gap describes — with real,
sourced evidence, not folklore assumed from memory. This is the load-bearing
finding of this whole document; everything below builds on it.**

### 1.1 What a client script *cannot* do (confirmed, primary source)

The public Lua `TriggerEvent(eventName, ...)` function used for a purely
local, same-context invocation is backed by the native `TRIGGER_EVENT_INTERNAL`.
Its declaration, read directly from `ext/native-decls/TriggerEventInternal.md`
in `citizenfx/fivem` (fetched via `raw.githubusercontent.com`, i.e. the
project's own native-declaration source of truth, not a wiki mirror):

```c
void TRIGGER_EVENT_INTERNAL(char* eventName, char* eventPayload, int payloadLength);
```

— "The backing function for TriggerEvent." **No parameter exists for the
caller to specify an origin/source for the dispatched event.** A script
calling the public `TriggerEvent` API — which is exactly what the 94fbc4e
comment's threat model describes ("a client's own local `TriggerEvent(name,
...)` invokes a RegisterNetEvent handler") — has no way, through that API,
to make the resulting invocation carry any particular origin marker of its
choosing. Confirmed by reading the native declaration itself; this is a
primary source, not a summary of one.

The complementary native, `TRIGGER_CLIENT_EVENT_INTERNAL` (`ext/native-decls/TriggerClientEventInternal.md`,
same repo, same fetch method) — "the backing function for `TriggerClientEvent`"
— is the one that actually dispatches an event *to* a specific client from
the server. `TriggerClientEvent` itself is a server-only Lua function (it is
not present in the client Lua environment at all — this is long-standing,
widely-relied-upon FiveM behavior, not something this pass re-derives from
scratch); a client script has no path to invoke it against itself to fake an
incoming server message. I was not able to fetch a primary-source
confirmation of `TRIGGER_CLIENT_EVENT_INTERNAL`'s apiset restriction (the
`.md` I read didn't state client/server availability explicitly) — flagged
as the one assumption in this chain not directly confirmed this session,
though it is about as safe an inference as any in this codebase (if a client
script *could* call this, the server→client trust boundary would already be
broken for every resource in the ecosystem, not just this one).

### 1.2 What the receiving client *can* check (two-source corroboration, one of them primary/official)

FiveM's own documentation — read via `raw.githubusercontent.com/citizenfx/fivem-docs`
(the actual markdown source backing `docs.fivem.net`, fetched through GitHub
since `docs.fivem.net` itself is egress-blocked in this environment; this is
the same content, not a third-party mirror) — states, on the "Secure your
events" page, verbatim as read:

> "The server will send net id `65535` for events from the server" — with
> the worked example:
> ```lua
> RegisterNetEvent("eventName", function(eventParam1, eventParam2)
>     if source ~= 65535 then return end
>     -- Process trusted server event
> end)
> ```

This is the **official, first-party recommendation for exactly this
scenario** — a `RegisterNetEvent` handler that should only ever legitimately
fire from a genuine server-sent trigger. Independent corroboration (second
source, community-level rather than primary, but converging on the same
number and the same semantics): multiple `forum.cfx.re` threads (titles
surfaced via search: "Source is returning 65535 in AddEventHandler," "Get
player ID for TriggerClientEvent") discuss `source` resolving to `65535` on
the client specifically for server-originated events, and explicitly warn
that `source` is *not* useful for identifying an individual player
client-side for this exact reason (it's a constant sentinel for "this came
from the server," not a per-player value the way server-side `source` is).
`forum.cfx.re` itself is egress-blocked in this environment, so I could not
read those threads directly — I only have `WebSearch`'s summary of them,
which I am treating as corroborating-but-unread, not independently verified
to the same bar as the two native `.md` files and the `fivem-docs` page
(which I fetched and read directly).

**Net conclusion, graded:**
- **HIGH confidence:** the public `TriggerEvent` API a self-triggering
  client would actually use cannot forge a custom event-origin value —
  confirmed directly from the native declaration.
- **MEDIUM-HIGH confidence:** checking `source ~= 65535` inside a
  client-side `RegisterNetEvent` handler is a real, officially-documented
  way to reject a locally-triggered invocation of that same handler. This is
  graded medium-high rather than confirmed-certain because (a) my
  corroborating community sources were read only as `WebSearch` summaries,
  not fetched and read directly (both primary docs domains and the forum
  are blocked), and (b) I did not independently trace the raw C++ engine
  code that sets `eventSource` for an inbound network `TriggerClientEvent`
  packet on the client (my one direct C++ fetch, `ResourceEventComponent.cpp`,
  showed `eventSource` exists as a parameter but that particular file didn't
  contain the code path that populates it for a networked receive — plausible
  path guesses for the right file 404'd). **Recommend the implementer
  empirically confirm this in a live client before relying on it**: print
  `source` and `type(source)` inside one of these handlers, once triggered
  genuinely by the server, and once triggered locally via
  `TriggerEvent('qbx_k9unit:client:forceRagdoll', 0)` from the same client's
  console/another test resource, and confirm the two are distinguishable and
  that the server-genuine case is reliably `65535` (note: the docs example
  compares against the bare number `65535`, implying client-side `source` is
  a Lua number in this context, not a string the way server-side `source`
  often is — worth confirming that type too, since a `"65535" ~= 65535`
  string/number mismatch would silently make the check always fail-closed,
  which is safe but would look like a mystery bug).

This is genuinely different from `PHASE3_SPEC.md` §12.0 item 8's own
conclusion for a related-but-distinct question (see §2 below) — item 8 asked
"can the server force a *different*, unwilling client's ped to comply" and
correctly answered no, with real, exhaustively sourced research
(`citizenfx/fivem` issues #3338, #2312, #3726). This document is not
re-opening or contradicting that answer. It is answering a different
question: "can *this client's own handler* tell whether the invocation it is
currently running came from the network or from itself" — and for that
narrower question, the answer is a qualified yes.

---

## 2. Architecture pivot — was asked for even if fully solvable, so addressed honestly

Per the task framing, even a working origin-check does not retroactively
validate Category B's whole shape, so this is addressed on its own terms.

**Category A/B (PHASE3_SPEC.md §12.0 item 8) already draws the right line,
and nothing found this pass argues for redrawing it.** The reason
`BiteAndHold`/`NonLethalTakedown`/`PropDragging`'s speed-limit half must be
applied by the *target's own client* is a structural FiveM property (a live
player's ped is that player's own client's simulation of their own input —
not a flag that migrates, per item 8 point 3's fully-sourced rejection of
forced network-ownership migration). No amount of origin-verification
changes that; a target's own client, having genuinely received the real
`applyBiteHold`, can still choose not to honor the restriction it just
received honestly (skip the `DisableControlAction` calls, or simply not run
this resource's code at all). **The origin-check from §1 does not, and
cannot, address that side of the problem — it was never trying to.** It
addresses a different failure mode entirely: not "the intended target
ignores a genuine instruction," but "an arbitrary, possibly *uninvolved*
player fabricates the instruction with zero server contact, against
themselves or against a third party's in-flight effect." Those need
different fixes, and this codebase already has the right fix for the first
one (item 8's detection-plus-guardrails posture, which stands unchanged) —
this document supplies the missing fix for the second.

**Should Category B ship at all, given a player can both ignore *and*
forge it?** Yes, on the same reasoning `PHASE3_SPEC.md` §12.0 item 8 already
worked through for "ignore" and this document extends to "forge": the
requester weighed and accepted the PvP-target decision with this tradeoff
disclosed (item 8's own "the requester already accepted this specific
tradeoff, with eyes open" framing), binding guardrail 3 already forbids any
server-authoritative consequence from ever hinging on a Category B effect
having actually landed, and — the actual news in this document — the *forge*
half of the problem (unlike the *ignore* half) turns out to have a real,
cheap, high-confidence mitigation available (§1 above), so accepting it
un-mitigated would be leaving a solvable gap open, not correctly recognizing
an unsolvable one. This is why the recommendation in §4 is "implement the
check," not "document as accepted risk" — the accepted-risk framing stays
reserved for the *ignore* half only, which is where it already correctly
lives (item 8's binding guardrails).

---

## 3. Real-world severity — neither inflated nor dismissed

**What a mod-menu client can already do, with no event involved at all:**
call `SetEntityCanBeDamaged(PlayerPedId(), false)` or
`SetPedToRagdollWithFall`/`SetPedMoveRateOverride` directly, on demand, any
time, feature-flag state notwithstanding — nothing in `qbx_k9unit` prevents
that, and nothing could (this is the same "a client that can call natives
directly already has the capability" baseline the task asks to weigh
against). **The incremental capability the forged-event path adds on top of
that baseline, before any fix, is real but narrow:**

- **Self-benefit (the 94fbc4e-fixed shape, now scoped to "any one mechanic
  enabled"):** a player who is *not* running a full native-calling mod menu
  — just a generic, ubiquitous "trigger any event" FiveM cheat menu (these
  are ubiquitous precisely because they need no native-calling capability of
  their own, only the public `TriggerEvent`/`TriggerServerEvent` Lua API,
  which is why this class of cheat is ecosystem-wide and low-effort to
  build/acquire) — gets a **capability equivalent to a native-calling mod
  menu, for free, off this resource's own event names**, the moment any one
  of `BiteAndHold`/`NonLethalTakedown`/`PropDragging` is enabled server-side.
  That gap between "generic low-effort event-menu user" and "someone who
  built or bought native-calling tooling" is exactly what a forged event
  erases, and it is the concrete, non-hypothetical harm the origin check in
  §1 closes.
- **Cross-player harm via the NPC-relay handlers — the scenario flagged in
  the task, confirmed real on reading the code.** `applyNpcBiteHold`/
  `endNpcBiteHold`/`applyNpcTakedown`/`endNpcTakedown` each take an arbitrary
  `npcNetId` chosen entirely by whoever fires the event — nothing about
  those four handlers scopes the `npcNetId` to "an NPC this client's own K9
  action legitimately targeted" (that scoping is done once, server-side, at
  request time, before the relay event is ever sent — the handlers
  themselves apply mechanically to whatever `npcNetId` argument they're
  handed, per this file's own header: "execute exactly what the server
  already decided, nothing more"). A hostile client — again, needing only
  the generic `TriggerEvent` API, no mod menu — can locally fire
  `endNpcBiteHold(<some other K9's live target's netId>, 'anything')` and
  attempt `SetBlockingOfNonTemporaryEvents(npcPed, false)` against an NPC a
  *different*, legitimately-certified K9 is mid-action against, stripping
  the flee-suppression that K9's own genuine hold established — a real
  cross-player griefing capability with no mod-menu-equivalent this simple
  (a native-calling mod menu could do the same thing, but would first have
  to resolve the same target NPC's netId itself; the event-relay path hands
  that resolution to the attacker for free, since the argument is unchecked).
  **This is the single strongest concrete justification for the fix in this
  document, independent of the self-invincibility angle** — it is other-K9
  harm, not merely rule-breaking self-benefit, and (per the note above) the
  actual success of the griefing attempt likely still depends on whether the
  hostile client can win the `NetworkRequestControlOfEntity` contest against
  the legitimate K9's own client (best-effort both ways, per this file's own
  "NETWORK OWNERSHIP OF THE TARGET PED" header note) — but the origin check
  removes the *zero-cost, zero-skill* version of even attempting it.
- **Not inflated:** none of this creates a money/item/permission/evidence
  exposure (matches item 8 guardrail 3's existing constraint, which this
  document doesn't touch), and the self-benefit half is bounded by the same
  `maxDurationMs`/`ragdollDurationMs` ceilings that already exist — a
  looping exploit before any fix is "loop the event every N seconds
  indefinitely," not "gain permanent, un-loopable invincibility outright."

---

## 4. Concrete recommendation for the next implementer

**File to change:** `qbx_k9unit/client/combat.lua` only (not touched this
pass — design-only, per this wave's assignment). **Not** a `server/combat.lua`
change — the fix lives entirely on the receiving side, and the server's own
routing (confirmed by reading `server/combat.lua`: every `TriggerClientEvent`
call site for these events already targets a specific `src`/`targetSrc`/
`holderSrc`, never a broadcast) needs no change.

**The change:** add a single guard line as the first statement inside every
`qbx_k9unit:client:*` `RegisterNetEvent` handler body in this file:

```lua
if source ~= 65535 then return end
```

Applies uniformly to all fourteen handlers currently in the file (listed for
completeness, not because they all carry equal severity — see §3's grading
above for which ones matter most):
`biteHoldStarted`, `biteHoldEnded`, `applyBiteHold`, `endBiteHold`,
`applyNpcBiteHold`, `endNpcBiteHold`, `forceRagdoll`, `endForceRagdoll`,
`applyNpcTakedown`, `endNpcTakedown`, `dragStarted`, `dragEnded`,
`applyDragSpeedLimit`, `endDragSpeedLimit`.

**What this closes:** the exact gap 94fbc4e's own top-level-gate comment
named as unfixed — self-triggering any of these handlers via the public
`TriggerEvent` Lua API, with zero server contact, once the owning mechanic's
feature flag is on. Confidence: medium-high (see §1.2's grading and its
recommended pre-ship empirical check — this is new to the codebase, no
existing file uses this convention yet, so it should not ship un-tested
against a live client).

**What this does NOT close, and must not be described as closing:**
1. `PHASE3_SPEC.md` §12.0 item 8's own gap — a legitimately-targeted
   player's client *honestly receiving* a genuine server-sent event and then
   choosing not to execute the restriction it applies (skip the
   `DisableControlAction` calls, patch out the local handler, etc.). That
   remains exactly as item 8 concluded: detectable (its point 2 design),
   not preventable (its point 3 research), already shipped as an accepted,
   guardrailed risk. This document's fix and that item's resolution are
   complementary, not overlapping — do not let a future pass read "the
   trust-boundary comment in 94fbc4e is now resolved" as "item 8 is also
   further resolved."
2. A client sophisticated enough to operate below the public Lua API layer
   (raw network packet forgery, a hooked/patched game process) — not
   evaluated as closed by this check, and not close-able by any client-side
   Lua-level mitigation this resource could add. This is the same class of
   adversary already asked to be treated as out-of-scope elsewhere in this
   codebase's own reasoning (a client with that capability already has
   direct native access and gains nothing incremental from forging this
   specific event).
3. The `NetworkRequestControlOfEntity` best-effort-only posture already
   disclosed in this file's own header ("NETWORK OWNERSHIP OF THE TARGET
   PED") — unaffected either way by who legitimately triggered the handler.

**Suggested residual-risk framing for `client/combat.lua`'s own header**,
for whoever implements this (not prescriptive wording, just the shape): a
short note next to the existing 94fbc4e gate comment saying the `source ~=
65535` guard is now this file's answer to the self-triggering half of that
comment's own "THIS GATE DOES NOT FIX" paragraph, with a one-line pointer to
this document and to `PHASE3_SPEC.md` §12.0 item 8 for the half that
remains open by design.

**Possible broader follow-up, flagged but not investigated further here (out
of this document's scope and this wave's file ownership):** every other
`client/*.lua` file's `RegisterNetEvent` handlers in this resource
(`partnership.lua`, `wellbeing.lua`, `main.lua`, `progression.lua`,
`movement.lua`, `medkit.lua`, `kennel.lua`, `search.lua`) have the identical
structural gap — none currently checks event origin. Most apply cosmetic or
already-idempotent state (bark sounds, HUD numbers, XP tier display) where
the incremental risk is low, but `client/medkit.lua`'s `applyMedkitHeal`
(`newHealth` argument) is a real self-benefit vector by the same shape as
this document's finding (free `SetEntityHealth`-class effect via a forged
event) and worth the same treatment. Not this document's file to fix or even
fully assess (medkit.lua is owned elsewhere this wave) — routed here as an
observation for whoever next reviews that file or considers this a
resource-wide convention (coder-architect's call, given it spans every
client file's own established pattern rather than one feature).

---

## Sources consulted this pass

- `ext/native-decls/TriggerEventInternal.md`,
  `ext/native-decls/TriggerClientEventInternal.md` —
  `raw.githubusercontent.com/citizenfx/fivem/master/...` (fetched and read
  directly; primary source).
- `content/docs/developers/server-security.md` —
  `raw.githubusercontent.com/citizenfx/fivem-docs/master/...` (fetched and
  read directly; this is the source backing the blocked `docs.fivem.net`
  page of the same name, reached via the docs' own GitHub repository rather
  than a mirror).
- `code/components/citizen-resources-core/src/ResourceEventComponent.cpp` —
  `github.com/citizenfx/fivem` (fetched and read; confirmed `eventSource`
  exists as a dispatch parameter but did not show the network-receive
  population path — inconclusive on its own, included for completeness).
- `WebSearch` results referencing `forum.cfx.re` threads ("Source is
  returning 65535 in AddEventHandler," "Get player ID for
  TriggerClientEvent") — corroborating but **not independently fetched**
  (`forum.cfx.re` is egress-blocked in this environment); graded
  accordingly in §1.2, not treated as equal-weight to the two primary
  sources above.
- `qbx_k9unit/PHASE3_SPEC.md` §12.0 item 8 (full text, lines ~642–1061) —
  read in full; this document's §2 explicitly builds on, and does not
  reopen, its conclusions.
- `qbx_k9unit/server/tracking.lua`'s "FORGED TRAIL DECISION" — read as the
  convention reference for accepted-risk framing (not applied as this
  document's own conclusion, since §1 found a real fix rather than an
  irreducible gap — see §2's explanation of why the two cases differ).
- `qbx_k9unit/client/combat.lua` (full file) and `qbx_k9unit/server/combat.lua`
  (grepped for every `TriggerClientEvent` call site) — read directly to
  confirm server-side routing is already correctly per-`src`-targeted, never
  broadcast, so no server-side change is implicated by this recommendation.
