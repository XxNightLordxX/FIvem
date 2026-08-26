# K9 Unit — Player Guide

This guide is for people who **play** on a server with this add-on
installed. It tells you what you can do, what to type or click, and what
you'll see when it works or doesn't. Checked directly against the current
code, not against a plan.

## A few words used below

- **Resource** — this K9 add-on.
- **Feature flag** — a switch, in a settings file only your server's staff
  can edit, that turns one piece of this resource on or off. If something
  below doesn't work, ask staff whether that piece is switched off for
  your server, or for you specifically (see "Is this stuff turned on for
  me?" below).
- **Radial menu** — the circular quick-actions wheel your server already
  uses. Open it however you normally do, then pick the "K9 Unit" icon.
- **ox_target** — the "look at something and press a key" prompt your
  server uses for interactions. Whenever this guide says "walk up to X,"
  this is what appears.
- **Server ID** — the number FiveM assigns a connected player for that
  session; changes on reconnect. Usually visible on a scoreboard or admin
  menu.
- **Citizen ID** — a character's permanent ID, used for commands that
  target someone who isn't online.

No command in this resource is gated by an ACE permission. Every gate is
either your character's job/rank, an explicit grant from high command, or
(for one developer-only tool near the end) a server-wide switch staff has
to turn on deliberately.

## Is this stuff turned on for me?

This resource ships with 56 independently-switched pieces.
**Nearly all of them ship on by default** — tracking, searching, combat,
gear, wellbeing, fetch, kennels, vests, XP, training, the shop, the
partner camera feed, and the command tablet included. The one exception
is certification expiry (off by default; ask staff if your server uses
it). Your server's staff can still switch any individual piece off, so if
something below doesn't work or a command isn't recognized, that's the
most likely reason — not a mistake on your part.

**A handful of features also need a personal OK from high command on top
of the server-wide switch**: Bite & Hold, Non-Lethal Takedown, Dragging,
Find Alerts, Scent Trail Hunt, Pursuit Sprint, Scent Lineup, SAR Calls,
and the staff-only audit commands (`/k9audit*` below). If one of these is
on for the server but you still get refused, ask a high-command officer
to grant it to you specifically from the command tablet.

Separately, your server's high command may also have set up
**certification tiers with extra requirements** — for example, reserving
Bite & Hold, Non-Lethal Takedown, or eligibility for a specialization to
one specific tier. This is off by default (a fresh server doesn't
restrict anything by tier), so most servers won't have this; if you're
refused with a message about your certification tier, that's what's
happening — ask a supervisor which tier you need.

One more thing worth knowing plainly: the combat features (Bite & Hold,
Non-Lethal Takedown, Dragging) rely on the *target's own game* to apply
the hold/ragdoll/slow-down, so a cheating player can ignore the effect.
That's a known, disclosed limitation, not a secret bug — see
`DEVELOPER_REFERENCE.md` if you want the technical detail.

---

## Quick command reference

Type these into chat exactly as shown; square brackets mean "put a real
value here."

### Certification and roster

| Command | What it does | Who can use it |
|---|---|---|
| `/k9certify [server id]` | Certifies someone as a K9 for their department | A qualifying supervisor/boss |
| `/k9certifyoffline [citizen id] [job]` | Certifies an offline player | Same |
| `/k9decertify [server id]` | Revokes an online player's certification | Same |
| `/k9decertifyoffline [citizen id] [job]` | Revokes an offline player's certification | Same |
| `/k9recertify [server id]` | Renews a certification before it lapses | Same |
| `/k9recertifyoffline [citizen id] [job]` | Same, offline | Same |
| `/k9settier [server id] [tier]` | Changes a K9's certification tier | Same |
| `/k9settieroffline [citizen id] [job] [tier]` | Same, offline | Same |
| `/k9specialize [server id] [specialization]` | Grants a specialization (e.g. `narcotics`) | Same |
| `/k9unspecialize [server id] [specialization]` | Removes an online K9's specialization | Same |
| `/k9unspecializeoffline [citizen id] [job] [specialization]` | Same, offline | Same |

### Everyday K9 work (on by default)

| Command | What it does |
|---|---|
| `/k9calmdown` | Calms your own stressed K9 down early |
| `/k9meatbait` | Uses a meat-bait item to distract a nearby K9 — anyone can use this |
| `/k9whistle` | Same, with an ultrasonic whistle |
| `/k9propattach` | Puts on/takes off the cosmetic K9 vest |
| `/k9throwfetchball` / `/k9dropfetchball` / `/k9recallfetchball` | Fetch: throw, drop, cancel |
| `/k9deploykennel` | Places a portable kennel |
| `/k9recall` | Calls your partnered K9 off whatever it's doing |
| `/k9nosehunt` / `/k9nosehunt stop` | Starts/abandons a scent-trail hunt |
| `/k9sarcall` / `/k9sarcall stop` | Starts/abandons a search-and-rescue call |
| `/k9lineup [id] [id] ...` | Starts a scent lineup with the listed players |
| `/k9lineuppick [id]` | Names your one guess in a lineup you're running |
| `/k9lineupcancel` | Cancels a lineup you're running |
| `/k9training on` / `off` | Enters/leaves the training yard drill mode |
| `/k9trainsearch` / `/k9trainbite` | Runs a practice drill (training mode only, no real target) |
| `/k9stats` | Shows the top K9 handlers by XP |
| `/k9tablet` | Opens the K9 Command Tablet (unless your server made it item-only) |

### Staff-only and developer-only

These check a high rank in an eligible department — you'll likely never
run these unless you're senior in a K9 department yourself. The five
`/k9audit*` commands additionally need an individual grant from high
command on the shipped default config (see "Is this stuff turned on for
me?" above) — meeting the rank alone, even as a department boss, is not
enough to run them unless your server has changed that default.

| Command | What it does |
|---|---|
| `/k9givexp [server id] [amount]` | High command: grants XP directly |
| `/k9auditcert [citizen id] [limit]` | High-rank + grant: certification history for one citizen |
| `/k9auditpartner [citizen id] [limit]` | High-rank + grant: partnership history |
| `/k9auditsearch <officer\|plate\|person\|recent> [value] [limit]` | High-rank + grant: search records |
| `/k9auditxp [citizen id]` | High-rank + grant: a K9's current XP total |
| `/k9auditdept [job] [limit]` | High-rank + grant: everyone currently certified in a department |
| `/k9bonetool ...` | Developer tool for lining up cosmetic attachment points. Needs a department-boss rank **and** a server-wide switch staff must turn on on purpose. Never on for regular play. |

---

## How this whole thing works

Two roles are usually involved, and — this is new — neither one requires
looking like a dog to start with:

- **The K9** — the certified/assigned party. By default, the moment
  someone is certified (or given the K9 role by high command), this
  resource **changes their character's appearance** to a configured K9
  model and remembers what they looked like before. Losing the role
  changes them back. Some servers turn this automatic swap off, in which
  case "the K9" is simply whoever already chose to look like a dog.
- **The handler** — a regular department employee who works with the K9.
  They don't need their own K9 certification for most of what's below.

A character can be both — nothing stops a supervisor from certifying
themselves if they also qualify.

---

## Becoming a K9 (certification)

Certification turns "a department member" into "a working K9 the game
treats as one." Without it, none of the K9-only options below appear.

### What's needed

1. You're hired into a K9-eligible department (police, sheriff, or BCSO by
   default — your server may have changed this).
2. A supervisor at or above the department's own rank threshold (or the
   department boss) certifies you.

You do **not** need to already be playing a dog-modeled character first —
if your server has the automatic appearance change on (the default), you
become one the moment you're certified.

### Getting certified

1. Stand close to the supervisor — within about 5 meters by default.
2. Either the supervisor walks up and clicks **Certify K9 Handler**, or
   types `/k9certify [your server ID]`.
3. You'll see **"You have been certified as a K9 handler."** If your
   server has the appearance swap on, your character changes to the
   configured K9 model within a few seconds.

Self-certification (`/k9certify` on your own ID) works by default, but
only from the chat command — the ox_target option excludes targeting
yourself.

### What can go wrong

| Message | What it means |
|---|---|
| "Target is not employed by an eligible department." | Their job isn't one your server allows K9s in. |
| "Target already holds an active certification for this department." | Already certified — nothing to do. |
| "Target is too far away to certify." | Get closer. |
| "Target must be online to be certified." | They have to be connected. |
| "You are not authorized to certify K9 handlers." | You aren't ranked high enough, or aren't in an eligible department. |
| "Self-certification is disabled on this server." | Ask a supervisor instead. |

### Tiers, renewal, and specializations

Every certification has a **tier** — `Trainee`, `Certified`, or `Senior`
by default (a supervisor sets it with `/k9settier`; your server's high
command can add more tiers from the command tablet). A K9 can also hold
one or more **specializations** — `narcotics`, `explosives`, or `patrol`
by default — granted the same way certification is.

If your server has **certification expiry** turned on, a certification
lapses a set number of days after it was granted (90 by default) unless a
supervisor renews it with `/k9recertify` first. You'll get an
in-session warning before it lapses — you should never find out by an
ability silently refusing to work. Most servers leave this off.

### Losing certification

A supervisor reverses the same two ways: click **Revoke K9 Certification**,
or `/k9decertify [server id]` (online) / `/k9decertifyoffline [citizen id]
[job]` (offline). Certification is also removed automatically and
immediately if you quit or lose your K9-eligible job. If your server has
the appearance swap on, losing certification changes your character back
to what you looked like before — unless nothing was ever recorded (a very
old install), in which case you're switched to a fallback human model
instead of being left stuck.

High command can also directly assign or remove the K9 role/appearance
for any citizen from the command tablet, independent of certification —
that's their tool, not something you trigger yourself.

---

## Putting a leash on a K9 (on by default)

Either side can start it, and **either side can end it whenever they
want, with no permission needed.**

1. Walk up to the other person and click **Attach Leash**, or use the
   radial menu's **Attach/Detach Leash**.
2. They get an Accept/Decline prompt. Nothing happens until they accept.
3. Once accepted: the K9 sees **"You are now leashed,"** the handler sees
   **"You are now anchoring the leash."**

While leashed, the K9 gets gently pulled back if they wander past about 6
meters, and the leash snaps entirely around 12 meters (**"Leash snapped —
you got too far from your handler."**). Either side can detach at any time
from the radial menu. If your partner disconnects, you'll see **"Leash
detached — your partner disconnected."**

| Message | What it means |
|---|---|
| "You are too far apart to attach a leash." | Get closer first. |
| "One of you is already leashed to someone else." | Detach first. |
| "The K9 is not certified for K9 duty." | The dog side isn't certified yet. |
| "The handler must be employed by an eligible department." | The handler side needs an eligible job (not their own K9 certification). |
| "Your leash request was declined." | Exactly what it says. |

---

## The K9 Radial Menu (on by default)

Opens a **"K9 Unit"** sub-menu from your server's regular radial. On a
default server it contains **Sit**, **Bark**, **Attach/Detach Leash**, and
**Enter/Exit Vehicle**. Every other item in this guide (tracking, combat,
fetch, kennel, gear, partnership, and so on) only appears here if your
server has that specific feature turned on.

Bark, and the three alternate bark styles under **Advanced Bark Radial**
(Alert/Aggressive/Calm), plus the ambient "K9 presence" sound that plays
based on distance, all have real audio behind them by default.

---

## Riding in a patrol vehicle (on by default)

Works on marked cars — `police`, `police2`, `police3`, `police4`,
`sheriff`, `sheriff2` by default.

1. Walk up to one, within about 3 meters, and click **Load K9 Into
   Vehicle**. You're tucked into the vehicle without needing your own
   seat. **"Loaded into the vehicle."**
2. To get out: walk up and click **Release K9 From Vehicle**, or use
   **Enter/Exit Vehicle** from the radial. **"Released from the vehicle."**

---

## Basic dog things (on by default, no certification needed)

- **First/third-person camera** — press **L** to switch view. Only works
  while playing a K9-modeled character.
- **Jump and crouch** — work normally (your server can disable this for
  K9s, but that isn't the default).
- **Sit** — from the radial menu. This one *does* need certification.

---

## World interactions, at a glance (ox_target)

| Walk up to... | Option | What it does | Needs |
|---|---|---|---|
| Any department member | **Certify K9 Handler** / **Revoke K9 Certification** | Grants/removes certification | Always available (rank-gated, not switch-gated) |
| A nearby player | **Attach Leash** | Starts a leash request | Leash Mechanics |
| An eligible patrol vehicle | **Load/Release K9** | Tucks you in/out | Vehicle Entry/Exit |
| A door | **Scratch to Alert** / **Nudge Door** | Alert sound / push animation — nudge can never open a locked door | Door Interaction |
| A vehicle or person | **Search Vehicle** / **Search Person** | Sniffs for contraband | Search Zones |
| A nearby player | **Partner Up** | Sends a long-term partnership request | Handler Partnership |
| A deployed kennel | **Pick Up Kennel** | Picks it back up | Deployable Kennel |
| A K9 player | **Pet K9** / **Feed K9** | Improves mood | Mood System |
| A K9 player | **Open K9 Gear** | Opens shared department storage for that K9 | K9 Inventory |
| A thrown fetch ball | **Pick Up Ball** | Picks it up | Fetch |
| A nearby player, carrying a ball | **Deliver Fetch Item** | Hands it over | Fetch |
| A K9 player | **Treat K9** | Heals with a medkit item | K9 Medkit |
| A K9 supply ped | *(opens the shop)* | Buy K9 items | K9 Supply Shop |

---

## Searching, tracking, and combat

**Searching** (needs Search Zones) — **Search Vehicle**/**Search Person**,
about a 4-second sniff, then **"Nothing found"**, **"Contraband
detected!"** (with a reaction sound scaled to how much was found), or a
real error. A 10-second cooldown per target stops repeat-fishing.

**Tracking** (needs its own switch per type: Scent/Blood/Gunpowder) — the
radial gets a **Track [type]** item that searches roughly 40 meters for
something trackable and draws a marker trail if found. Water breaks the
trail by default. **Find Alerts**, if also on, makes your K9 automatically
sit and bark on a real find or a completed trail — the same result you
already get, with a stronger reaction on top.

**Combat** (Bite & Hold / Non-Lethal Takedown / Dragging, each its own
switch) — only ever usable against a player your server's dispatch has
flagged **wanted**, never an ordinary bystander:

- **Bite & Hold / Release** — holds a target in place, up to 15 seconds
  automatically.
- **Non-Lethal Takedown** — only works on a fast-moving (fleeing) target.
- **Drag / Release** — drags a target, up to 30 meters or 20 seconds.

You'll see messages like "That target is not currently eligible," "You
are too far from the target," or "You must wait before attempting that
again" if a request is refused.

**Advanced Agility** (needs its own switch) — press **X** near a low
obstacle (up to ~1.2m) to vault it. Short cooldown between attempts.

**Pursuit Sprint** (needs its own switch, own personal grant) — a short
burst (a few seconds, on a cooldown) where a certified K9 is genuinely
faster than the wanted target it's chasing. Meant to end a chase already
going your way, not to make escape impossible.

---

## Handler Partnership, Handler-Down Defense, and Recall

**Partnership** (needs its own switch) — a longer-term bond, separate
from the leash. Walk up and click **Partner Up**, or use the radial; the
other side gets an Accept/Decline prompt. Either side can **Break
Partnership** at any time, no confirmation needed.

**Handler-Down Defense** (needs Partnership **and** its own switch) — if
a partnered handler's health drops low near their K9, the K9 sees
**"Your handler is under attack! Press G to respond, or use the radial
menu."** (`G` by default). Confirming brings up the same response a
player could pick manually, faster — the K9 never acts on its own.

**Recall** (needs Partnership **and** its own switch) — the handler types
`/k9recall` or uses the radial's **Recall K9** to immediately call their
K9 off whatever it's doing. This always works, with only a short cooldown
between uses, so a partner is never stuck.

---

## K9 wellbeing (five independent switches, all on by default)

- **Mood** — **Pet K9** (free) or **Feed K9** (needs a treat item).
- **Fatigue** — builds while sprinting, recovers while resting (faster
  near a water bowl object, if your server placed one).
- **Fear/Stress** — rises from nearby gunfire; high stress makes the K9
  refuse combat commands temporarily ("Your K9 hesitates, too stressed to
  act."). Use `/k9calmdown` to reduce it yourself.
- **Distraction** — `/k9meatbait` and `/k9whistle` are deliberately open
  to **any player**, including someone being chased.
- **Injury/Limping** — blocks sprint/jump entirely below a threshold; the
  main fix is a K9 Medkit, plus slow natural recovery.

Low Mood, Fatigue, or Injury each slightly slow the K9 down; they can
stack.

## K9 Medkit (needs its own switch)

Walk up to an injured K9 and click **Treat K9** — needs a medkit item and
usually an eligible department or ambulance job. A cooldown applies per
K9. **"K9 treated."** on success.

## K9 Gear (needs "K9 Inventory")

**Open K9 Gear** opens a small shared storage container tied to that K9 —
anyone in an eligible department can use it, the same way a patrol car's
trunk usually works.

## Fetch (needs its own switch)

`/k9throwfetchball` (or radial: Fetch → Throw) — a K9 walks up and clicks
**Pick Up Ball**, then delivers it with **Deliver Fetch Item** near a
handler. `/k9dropfetchball` drops it early; `/k9recallfetchball` (the
thrower's own command) cancels the whole thing. A ball disappears after 5
minutes if nobody finishes. The K9 doesn't walk it back on its own — a
real player carries it, on foot.

## Deployable Kennel (needs its own switch)

`/k9deploykennel` (or radial: Deploy Kennel) places a portable kennel a
couple of meters ahead. Only one at a time — pick it up first
(**Pick Up Kennel**) before placing another.

## K9 Vest (needs "Prop Attachments")

`/k9propattach` (or radial: Toggle K9 Vest) toggles a cosmetic vest. The
attach point hasn't been fine-tuned on every server yet, so it may sit at
an odd spot until your staff runs the calibration tool.

## Thermal and night vision (two independent switches)

**K** toggles thermal, **J** toggles night vision (your server may have
remapped these). Work for **any** player currently on a K9-modeled
character, even uncertified — treated as the dog's own senses, not a
department privilege. Turning one on turns the other off.

## Partner camera feed (needs "Handler Partnership")

Press **H** (your server may have remapped this) to switch your *entire
screen* to your active partner's viewpoint — a real full-screen switch,
not a small inset window, and not a literal picture-in-picture (that's
not possible in this game). Press **H** again to switch back. Needs an
active partnership (see below) and works for the K9 or the handler side,
whoever presses it. It automatically ends and gives your view back if
your partner disconnects, goes out of range, you die, or you lose access
to K9 features mid-view — you're never stuck watching through it. Your
own character stands still and can't act while it's active, the same way
looking at a menu would.

## Training Mode (on by default)

A practice sandbox. Stand in a training yard (your server's staff sets
where), type `/k9training on`, then run `/k9trainsearch` or
`/k9trainbite` to rehearse the search or bite-and-hold flow against a
scripted dummy. Nothing here touches a real player, a real inventory, or
awards any XP — it's purely practice. `/k9training off` leaves the mode.

## K9 Supply Shop (needs its own switch)

Walk up to the K9 Supply ped (a real, visible dog attendant — your
server's staff sets its location) to buy medkits, treats, meat bait, and
whistles. Prices and payment come out of your inventory's own currency
item, same as any other in-game shop.

## The K9 Command Tablet (on by default)

Open it with `/k9tablet` (unless your server made it item-only — check
for a "K9 Tablet" item instead), or from the radial menu. Everyone gets a
read-only view of their own certification, XP, and any personal grants.
High command additionally gets a full roster and a much bigger toolbox:
certify people and set their certification tier, assign/revert the K9
role and appearance, grant XP and permissions, adjust what individual
people can access, add or relabel certification tiers and permission
keys, change the XP required for each rank, add/move/remove K9 Supply
Shop locations, flip most feature switches and tune numbers live without
a restart, and restyle the tablet itself. A separate, read-only audit
trail (certification, partnership, search, XP, and department-roster
history) is also open to anyone who separately qualifies for the staff
audit commands, not only high command — see "Staff-only and
developer-only" above. The tablet never grants anything by itself —
every button it offers is re-checked exactly like the matching chat
command would be.

## XP and tiers (needs "XP Progression")

Real actions (finding contraband, resolving a track, certain combat/SAR
actions) earn XP.

| Tier | XP needed | Bonus |
|---|---|---|
| Recruit K9 | 0 | none |
| Trained K9 | 1,250 | slightly faster, slightly better tracking range |
| Veteran K9 | 4,000 | more of the same, plus a shorter K9 Medkit cooldown |
| Elite K9 | 9,000 | the most of the same, plus a cosmetic HUD badge |

**"Your K9 has reached the [tier] tier!"** on level-up. Only the
staff-only `/k9auditxp` command shows your exact number; `/k9stats` (needs
"K9 Leaderboard") shows the server's top handlers by XP to anyone with K9
access — that means other players' citizen IDs and totals are visible to
each other on servers that leave this on.

## Vitality display (needs "Health/Stamina HUD")

A small passive on-screen readout of your K9's health and stamina.
Nothing to click.

## Contraband screen effect (needs its own switch, and Search Zones)

A brief, disorienting effect on *your own* screen (the searching K9's)
when a search turns up a large stash. Feedback for you, not a penalty on
whoever you searched.

---

## Scent Trail Hunt, SAR Calls, and Scent Lineup

Three "hunting" mini-games, each its own switch and each requiring a
personal grant from high command on top of that switch (see "Is this
stuff turned on for me?" above).

- **Scent Trail Hunt** — `/k9nosehunt` sets your K9 off after a hidden
  spot somewhere nearby. There's no marker or blip — only a growl that
  pulses faster as you get closer. The location is never sent to your
  game at all, only a distance, so there's nothing to read the answer out
  of. `/k9nosehunt stop` abandons it. No XP.
- **SAR Calls** — `/k9sarcall` requests a search-and-rescue call: your dog
  reacts more strongly the closer you get to a hidden target. Finding it
  always resolves as a rescue — nobody is arrested, and the "missing
  person" is scenery that only appears once the call is already solved,
  never a real player. `/k9sarcall stop` gives up early.
- **Scent Lineup** — `/k9lineup [id] [id] ...` invites 2–6 other online
  players to line up (everyone has to accept). Once they have, the server
  secretly picks one — nobody, not even you, is told who until you commit
  your one guess with `/k9lineuppick [id]`. `/k9lineupcancel` calls it
  off. No XP, since the outcome is random.

---

## Common messages you might see anywhere

| Message | What it means |
|---|---|
| "You cannot use K9 features right now." | You're not certified, not a K9 model (if your server still requires one), or both. |
| "This only works while playing a K9 character." | Applies to camera/vision toggles. |
| "That player is no longer online." | They disconnected before your action went through. |
| "Get closer to the K9 first." | Move closer and try again. |
| (No message at all) | Some actions are silent on a repeat attempt that's too soon — intentional, not a bug. |

## A note on fairness and safety

- **You can never be permanently trapped.** Leashes, bite holds, drags,
  and partnerships can always be ended by at least one side, and several
  have hard time limits regardless.
- **Combat actions only ever target a wanted player** — never an ordinary
  bystander.
- **Distraction items are deliberately open to everyone**, including
  someone actively being chased. By design, not an oversight.
- The combat mechanics' known cheat-resistance limits are disclosed, not
  hidden — ask your server's staff or see `DEVELOPER_REFERENCE.md` if
  you want the detail.
