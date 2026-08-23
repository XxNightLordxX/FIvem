# Scent tracking — server-side source resolution (SPEC.md §9 items 11 & 17)

Author: tech-scout pass, 2026-08-23. Research-only — **no `.lua` file
touched**, per this task's explicit instruction. This closes the open
verification gap `server/tracking.lua`'s header and SPEC.md §9 items 11/17
flag: whether a real `ox_inventory` mechanism exists for "an item was
dropped/placed at this world coordinate."

**Bottom line: YES, a real, confirmed, documented mechanism exists.** It is
not literally a `dropitem`/`DropItem`-named export or a simple
`TriggerEvent('ox_inventory:itemDropped', coords)`, but it is a real,
first-party, server-side hook that fires exactly when a player drops an
item, and it is a strictly better fit for this codebase's existing
security posture than a naive coordinate-carrying event would have been.
The client-side world-entity-scan fallback described in SPEC.md §11.6 /
`server/tracking.lua`'s header is **not needed** — do not build it; it
would be strictly worse (client-supplied position data) than the mechanism
below.

---

## 1. What was checked, and how

Read directly from `overextended/ox_inventory@main` (raw GitHub source,
same repository `phase2_notes/contraband_search_contract.md` already
verified real exports against for the search feature — this pass extends
that verification, doesn't duplicate it):

- `modules/inventory/server.lua` — the `dropItem` function (fired when a
  player drags an item to the "ground" in the ox_inventory UI) and the
  `CustomDrop` function (the exported helper other resources use to spawn
  a drop programmatically, e.g. death drops, admin tools).
- `modules/hooks/server.lua` — the `registerHook`/`removeHook` export
  system and the `TriggerEventHooks` dispatcher those two functions above
  call into.
- `server.lua` (top-level) — every plain `TriggerEvent(` (server-local,
  not `TriggerClientEvent`) call, to rule out a simpler "just listen for a
  local server event" path.

`docs.fivem.net`, `overextended.dev`, and `coxdocs.dev` (the canonical doc
sites, including the mirror) were all blocked by this environment's egress
proxy for this pass, same as prior tech-scout/native-api passes in this
repo's history — every claim below is instead cross-checked directly
against the live GitHub source, which is a **stronger** source than the
rendered docs anyway (it's not possible for it to be stale or
paraphrased). Where the source wasn't independently re-fetchable a second
time to triple-check, that's noted.

---

## 2. The real mechanism: `exports.ox_inventory:registerHook('swapItems', ...)`

This is a genuine, documented, public export (`modules/hooks/server.lua`,
confirmed via source: `exports('registerHook', function(event, ref,
options) ... end)`). Any resource's server script can call it at startup:

```lua
local hookId = exports.ox_inventory:registerHook('swapItems', function(payload)
    -- payload.source, payload.fromInventory, payload.fromType,
    -- payload.toInventory, payload.toType, payload.fromSlot, payload.toSlot,
    -- payload.count, payload.action, payload.dropId (only present when a
    -- brand-new drop pile is being created)
end, {
    -- optional filters: itemFilter = {...}, inventoryFilter = {'^pattern'},
})
```

Confirmed from `modules/inventory/server.lua`'s actual `dropItem` function
body (the code path that runs when a player drags an item onto the ground
in the ox_inventory UI):

```lua
local hooks <close> = TriggerEventHooks('swapItems', {
    source = source, fromInventory = playerInventory.id,
    fromSlot = fromData, fromType = playerInventory.type,
    toInventory = 'newdrop', toSlot = data.toSlot,
    toType = 'drop', count = data.count,
    action = 'move', dropId = dropId,
})
if not hooks.success then return end
-- ... only after this does ox_inventory actually create the drop
-- inventory (Inventory.Create(dropId, ...)) and set its .coords.
```

**This is a real, synchronous, server-side "an item is about to be
dropped" notification** — `swapItems` fires on every slot-to-slot item
move ox_inventory processes (trunk transfers, stash transfers, giving an
item to another player, and — the case we care about — dropping an item
on the ground), and any hook registered for it can inspect `payload.toType
== 'drop'` to identify specifically a drop-to-ground action. Returning
`false` from the hook would even cancel the drop (not needed for
tracking, but confirms this genuinely runs *before* the drop completes,
not as an after-the-fact log).

**Important timing/shape detail for whoever implements this:** the hook
fires **before** `Inventory.Create(dropId, ...)` runs, so
`exports.ox_inventory:GetInventory(dropId)` would return `nil` if called
*from inside* the hook callback itself — the drop inventory (and its
`.coords` field) doesn't exist yet at that point. This matters because it
rules out the tempting-looking approach of "look up the new drop's coords
from ox_inventory once notified of its id." See §4 for why this doesn't
matter in practice.

**Caveat — could not independently confirm the complete, current,
version-pinned hook-name enum a second time.** `swapItems` is corroborated
in two independent ways this session (the `dropItem` source call site
above, and a search-engine-summarized doc snippet showing an example
`registerHook('swapItems', ...)` registration with `itemFilter`/
`inventoryFilter` options) — I'm confident this hook name is real and
current. I was not able to fetch the canonical hook-name reference table
from `overextended.dev`/`coxdocs.dev` directly (both blocked), so a version
skew (a hook rename in some future ox_inventory release) can't be ruled
out with 100% certainty from source-reading alone. Whoever implements this
should do a one-line sanity check against the actual `ox_inventory`
version vendored on the target server (log `json.encode(payload)` from the
hook once, during dev, and confirm the shape matches this note) before
shipping — cheap, and closes the last sliver of doubt.

---

## 3. Alternative/secondary mechanism confirmed too: the `'drop'` inventory type is a real, queryable "ground" inventory

Answering the task's second question directly: **yes**, exactly like
`contraband_search_contract.md` already confirmed for `'trunk' .. plate`,
a dropped item becomes its own inventory of `type = 'drop'`, keyed by a
generated `dropId` string (not by raw coordinate, but the id resolves to a
coordinate — see below), created via the same internal `Inventory.Create`
path every other inventory type uses. Confirmed from source
(`CustomDrop`'s body, `modules/inventory/server.lua`):

```lua
local function CustomDrop(prefix, items, coords, slots, maxWeight, instance, model)
    local dropId = generateInvId()
    local inventory = Inventory.Create(dropId, ('%s %s'):format(prefix, dropId:gsub('%D', '')),
        'drop', slots or shared.dropslots, 0, maxWeight or shared.dropweight, false, {})
    if not inventory then return end
    inventory.items, inventory.weight = generateItems(inventory, 'drop', items)
    inventory.coords = coords
    Inventory.Drops[dropId] = { coords = inventory.coords, instance = instance, model = model }
    TriggerClientEvent('ox_inventory:createDrop', -1, dropId, Inventory.Drops[dropId])
    return dropId
end
exports('CustomDrop', CustomDrop)
```

So once a `dropId` is known, `exports.ox_inventory:GetInventory(dropId)`
/ `GetInventoryItems(dropId)` (the exact same generic exports
`contraband_search_contract.md` §1 already confirmed and that
`server/search.lua` is being built against) work against it identically to
any stash/trunk id, and would return `.coords` once the drop inventory has
actually been created (i.e., any time after the `swapItems` hook above has
returned). This is a legitimate way to later re-confirm or re-query a
drop's exact coordinate and contents if a future feature ever wants that
(e.g., a "what's in this scent source" detail), but per §4 below it is
**not the recommended way to get the coordinate for tracking purposes** —
resolving the dropping player's own live position is simpler, already the
established pattern in this file, and avoids adding a second call/await
into the hot path.

**Also confirmed, not needed for this design but worth recording:** ox_inventory
broadcasts `TriggerClientEvent('ox_inventory:createDrop', -1, dropId,
Inventory.Drops[dropId], ...)` — a **client** event, sent to literally
every connected client (`-1`), whose payload includes the real `.coords`.
Any resource's *client* script could technically `RegisterNetEvent` this
and see live drop coordinates as ox_inventory's own server computed them.
This was considered and **deliberately not recommended** as the primary
mechanism: using it would mean `client/tracking.lua` relaying that
coordinate up to `qbx_k9unit`'s own server via a new event, which
reintroduces exactly the "trust a client-claimed coordinate" problem this
file's own header and `findTrackableSource`'s docstring go out of their
way to avoid for blood/gunpowder. The `registerHook` path in §2 avoids
this entirely by staying server-to-server.

---

## 4. Recommended design for `server/tracking.lua`'s `'scent'` branch

**Do not treat scent as a live per-query scan against ox_inventory drop
data.** The file's current header ("STRUCTURAL NOTE... 'scent'
intentionally has NO entry in `TrackableLog`... scent sourcing is a live
query against ox_inventory drop data") describes a plan that turns out to
be the *harder*, less-idiomatic option now that a real event-style hook is
confirmed. The natural fit, once `registerHook('swapItems', ...)` is
known to be real, is to make scent **structurally identical to
blood/gunpowder** — a `TrackableLog.scent` entry fed by an event, pruned
on the same schedule, queried the same way — which also means this file's
existing "STRUCTURAL NOTE" comment and the `TRACK_TYPE_CONFIG`/`TrackableLog`
tables described in this file's header will need updating to *add* a
`scent` entry, not preserve its absence. (Flagging the exact comment
that goes stale, since it currently instructs future editors *not* to add
one "without re-reading §11.6's actual design first" — this note is that
re-read.)

Concretely, at resource start (`server/tracking.lua`, alongside the
existing `RegisterNetEvent`s):

```lua
exports.ox_inventory:registerHook('swapItems', function(payload)
    if payload.toType ~= 'drop' then return end -- only care about "item entered the world," not trunk/stash/give moves

    -- Mirrors relayDamageEvent/relayWeaponFire's own established rule:
    -- resolve the ACTING PLAYER'S OWN live position server-side, never a
    -- client-claimed or ox_inventory-internal coordinate. payload.source
    -- is ox_inventory's own resolved `source` for the request (the same
    -- trust level as any RegisterNetEvent's ambient `source` global) —
    -- not a value the dropping client can freely relabel.
    local ped = GetPlayerPed(payload.source)
    if ped == 0 then return end

    TrackableLog.scent[#TrackableLog.scent + 1] = {
        coords = GetEntityCoords(ped),
        loggedAt = GetGameTimer(),
    }
end)
```

This mirrors `relayDamageEvent`/`relayWeaponFire` almost exactly — same
"resolve the reporting party's own live server-side position, never trust
a claimed coordinate" rule already established and reviewed for this
file — except there is no `TriggerServerEvent`/client relay step at all,
because `registerHook` already delivers the notification server-side.
That's a strictly smaller trust surface than blood/gunpowder have today
(no client relay to rate-limit against a modified-client forgery at all —
`payload.source` cannot be spoofed to claim a drop that didn't happen,
unlike `relayDamageEvent`'s payload-less design which still trusts the
*fact* of the client's report). This also means scent tracking does not
need — and should not get — the `relayCooldownMs`-style logging-rate-limit
this file's header's "FORGED TRAIL DECISION" section had to accept as a
residual risk for blood/gunpowder; there's no client-triggerable path into
this hook at all.

Then `findTrackableSource`'s `'scent'` branch (currently hardcoded
`sourceCoords = nil`) becomes identical in shape to the existing
`'blood'`/`'gunpowder'` branch — the `if trackType == 'scent' then ...
else ...` special-case can simply be deleted, folding `'scent'` into the
same nearest-fresh-entry-within-`maxRange` loop already written for
`'blood'`/`'gunpowder'`, once `TrackableLog.scent = {}` exists alongside
`TrackableLog.blood`/`TrackableLog.gunpowder` and it's added to
`PruneTrackableLogs`'s two hand-rolled loops (or that function is
refactored to loop over `{'blood','gunpowder','scent'}` generically — a
nice small cleanup, not required).

**Config addition needed (not made here — `config.lua` is a `.lua` file
and out of scope for this pass):** `Config.Tracking.Scent` currently has
only `maxRange`/`markerSpacing`/`searchCooldownMs` (confirmed by reading
`config.lua`); unlike `Blood`/`Gunpowder` it has **no** `maxAgeSeconds`.
Adopting the `TrackableLog`-backed design above means `Config.Tracking.Scent.maxAgeSeconds`
needs adding (how long a dropped item stays "trackable" — likely
*longer* than blood/gunpowder's 300s/120s, since a physical dropped item
sitting on the ground doesn't inherently decay the way a damage/gunfire
event does; that's a judgment call for whoever picks this up, possibly
worth a quick check-in with product-manager/config-validator since it's a
gameplay-balance number, not a security one). No `relayCooldownMs` is
needed for scent, per the trust-surface note above.

**One real product/design question this note surfaces, not decided
here:** should *every* dropped item register as a scent source, or only
items on `Config.SearchContrabandItems` (mirroring the "only contraband
matters" framing search/contraband already uses)? The hook payload does
carry enough information to filter by item name if desired
(`payload.fromSlot.name` — the item being moved — is present in the
`dropItem` call site's payload construction), but SPEC.md §6.3's original
language ("nearest configured scent source (dropped item/stash
location)") doesn't clearly commit either way. Flagging for
product-manager/config-validator rather than assuming — this is a
gameplay-scope decision, not a technical blocker (the hook works either
way).

---

## 5. Why the client-side world-entity-scan fallback is now unnecessary

SPEC.md §11.6 and `server/tracking.lua`'s header both name a fallback:
scanning for dropped-item prop entities near a search radius (e.g. via
`GetGamePool('CObject')` or similar) if no server-side ox_inventory hook
existed. Since §2 above confirms a real, server-side, non-client-trusting
hook *does* exist, **this fallback should not be built** — it would be
strictly worse on every axis that matters here:

- **Trust:** a client-side entity scan's result (which entity, therefore
  which coordinate) would have to be relayed to the server as a claim,
  reintroducing exactly the "client-claimed coordinate" problem
  `registerHook` avoids entirely by running server-side, before any client
  is even involved in reporting.
- **Reliability:** identifying "a dropped-item prop" generically via
  `GetGamePool('CObject')` would require matching against ox_inventory's
  actual drop prop model/archetype — not independently confirmed this
  session, and not necessary to confirm now that it's moot. (For the
  record, had this fallback been needed: dropped items in ox_inventory are
  **not** spawned as visible pickup props by default in most configurations
  — `ox_inventory:createDrop` creates an *inventory*, not automatically a
  streamed world prop; some servers pair it with a separate visual pickup
  resource. This would have made the "which prop model is a drop"
  assumption in SPEC.md's own fallback sketch shakier than it reads at
  first glance — another reason not to build it.)
- **Effort:** the hook-based design in §4 is a small, self-contained
  addition that reuses 100% of this file's existing `TrackableLog`
  infrastructure. The scan-based fallback would have needed new
  client-side polling, a new relay event, new server-side trust reasoning
  for why a scan result is safe to act on (it wouldn't have been, cleanly),
  and a fresh security review — real, multi-file work for a strictly worse
  outcome than what §4 describes.

---

## 6. Confidence summary

| Claim | Confidence | Basis |
|---|---|---|
| `exports.ox_inventory:registerHook` exists, is a real public export | High | Directly read from `modules/hooks/server.lua` source this session |
| `'swapItems'` is a real, currently-used hook name | High | Directly read from `modules/inventory/server.lua`'s `dropItem` function body (the actual `TriggerEventHooks('swapItems', {...})` call site), corroborated by an independent doc-snippet example registration |
| `swapItems` payload includes `source`, `toType`, `dropId` for a drop action | High | Directly read from the same `dropItem` source | 
| Hook fires *before* the drop inventory/coords exist | High | Directly read: `TriggerEventHooks` call precedes `Inventory.Create`/`inventory.coords =` in the same function |
| `'drop'`-type inventories are queryable via the same `GetInventory`/`GetInventoryItems` exports used for trunks | High | Directly read from `CustomDrop`'s source, consistent with `contraband_search_contract.md`'s already-confirmed generic export behavior |
| `'ox_inventory:createDrop'` client event broadcasts real coords to all clients | High | Directly read from both `CustomDrop` and `dropItem` source |
| No complete, current, canonical hook-name enum was independently fetched from the primary docs site | Explicitly unconfirmed | `docs.fivem.net`/`overextended.dev`/`coxdocs.dev` all blocked this session — recommend a one-time dev-time payload log as a cheap final check before shipping |
| Whether dropped items are also visually represented as world pickup props by default | Not confirmed, and not needed | Moot once the hook-based design (not a prop scan) is adopted — noted only because it would have undermined the originally-sketched fallback |

---

## 7. Handoff

This is research only — no `.lua` file was touched. Concrete next steps
for whoever implements it (coder-backend, most likely, since this extends
`server/tracking.lua` exactly the way `relayDamageEvent`/`relayWeaponFire`
are already structured):

1. Add `Config.Tracking.Scent.maxAgeSeconds` to `config.lua` (product/config
   call on the actual duration — see §4's open question).
2. Add `TrackableLog.scent = {}` and register the `registerHook('swapItems',
   ...)` handler from §4 in `server/tracking.lua`.
3. Fold `'scent'` into the existing prune loop and the existing
   `'blood'/'gunpowder'` nearest-match loop in `findTrackableSource`,
   removing the hardcoded `sourceCoords = nil` special case.
4. Update this file's own header comment (the "STRUCTURAL NOTE" and "SCENT
   BRANCH STATUS" blocks) to reflect the new design instead of the old
   "still unconfirmed" framing — those comments are now stale as of this
   note.
5. Decide (product-manager/config-validator) whether to filter which
   dropped items count as scent sources, per §4's open question.
6. One-time sanity check in dev: log the `swapItems` payload once against
   the actual `ox_inventory` version running on the target server to
   confirm the field names in this note still match (closes the residual
   version-skew doubt noted in §2/§6).

SPEC.md §9 item 17 has been updated with a short pointer to this file (see
SPEC.md itself) — this note is complete enough to fold in directly, not a
placeholder needing a second pass.
