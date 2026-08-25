# K9 Unit — Player Guide

This guide is for people who **play** on a server that has this add-on
installed — not for developers. It tells you what you can do, exactly what
to type or click, and what you'll see when it works or doesn't.

Everything in this guide was checked directly against the actual code as it
exists right now, not against a plan or a wish-list. Where something isn't
turned on by default, that's said plainly, in the same sentence — not buried
in a footnote.

## Words used in this guide

A few words come up a lot below. Here's what they mean in plain English:

- **Resource** — an add-on a FiveM server installs. "This resource" means
  this K9 add-on specifically.
- **Feature flag** — a switch, in a settings file only server owners can
  edit, that turns one small piece of this resource on or off. You can't
  flip these yourself — if something below isn't working and this guide
  says it should be on, ask your server's staff whether they've switched
  that specific piece off.
- **Radial menu** — a circular pop-up wheel of quick actions. You open it
  with a keybind (set by your server, not by this resource — check your
  keybind settings or ask staff if you don't already use one), then click
  or hover over an icon to pick an action.
- **ox_target** — the add-on this server uses to show a small pop-up option
  (like "Search Vehicle") when you look at something and stand close
  enough to it. Whenever this guide says "walk up to X," this is what pops
  up.
- **Server ID** — a number FiveM assigns to a connected player for that
  session. It changes every time they reconnect. Several commands below
  need it. Most servers show it somewhere — a scoreboard, the pause menu,
  or an admin console command — ask your server's staff if you can't find
  it.
- **Citizen ID** — a permanent ID for one specific character, unlike a
  server ID. Used for commands that need to work on someone who isn't
  online right now.
- **ACE permission** — a permission flag server owners grant to specific
  people (usually staff). A few commands near the end of this guide need
  one; regular players won't have it and won't be able to use those
  commands.

## Is this stuff even turned on for me?

This resource ships with roughly forty separate pieces, each with its own
on/off switch, that your server's staff controls. **As of this guide's last
check (2026-08-25), every single one of them is turned on** — including
tracking, searching, combat, gear, health/mood systems, fetch, kennels,
vests, and XP. That's a change: earlier versions of this guide said only
five were on by default, and that used to be true. It no longer is.

**Your server's staff can still turn any individual piece back off at any
time**, so if you try something below and nothing happens, or the game
says it doesn't recognize a command, that means the feature has been
switched off on your server specifically — not that you did something
wrong, and not that this guide is wrong. Ask your server's staff if
something below doesn't seem to work.

One thing worth knowing, plainly: the combat features (Bite & Hold,
Non-Lethal Takedown, Dragging — see below) come with an unresolved
technical question about whether a cheating player could exploit them,
and a separate, known way a stranger could repeatedly jam one K9's combat
commands for about a minute at a time. Neither is something you as a
player can fix, and neither means the features are broken for normal play
— they're mentioned here so you know this isn't a secret if you notice
odd behavior. Ask your server's staff if you want the technical detail
(it's written up in `PROJECT_STATUS.md`).

---

## Quick command reference

Type these into your in-game chat box exactly as shown. Square brackets
mean "put a real value here, without the brackets."

### Commands anyone can try (these exist on every server)

| Command | What it does | Who can actually use it |
|---|---|---|
| `/k9certify [server id]` | Certifies another player as a working K9 for their department | Only a department supervisor or boss — see [Certifying a K9](#certifying-a-k9-becoming-official) |
| `/k9decertify [server id]` | Removes an online player's K9 certification | Same as above |
| `/k9decertifyoffline [citizen id] [job]` | Removes an *offline* player's K9 certification | Same as above |

### Commands that exist, but need a feature turned on to do anything

Every feature in the "needs" column below is turned on by default as of
this guide's last check — these commands should work out of the box. If
your server's staff has switched one back off, the matching command below
stops working (see "On a server where the feature is off," further down).

| Command | What it does | Feature it needs |
|---|---|---|
| `/k9calmdown` | Calms your own stressed-out K9 down | Fear/Stress system |
| `/k9meatbait` | Uses a meat-bait item to distract a nearby K9 — **anyone can use this, even someone a K9 is chasing** | Distraction system |
| `/k9whistle` | Uses an ultrasonic whistle to distract a nearby K9 — same, open to anyone | Distraction system |
| `/k9propattach` | Puts on or takes off a cosmetic K9 vest | Prop Attachments (experimental) |
| `/k9throwfetchball` | Throws a fetch ball | Fetch |
| `/k9dropfetchball` | Drops the fetch ball you're currently carrying | Fetch |
| `/k9recallfetchball` | Cancels your own throw and removes the ball | Fetch |
| `/k9deploykennel` | Places a portable kennel | Deployable Kennel (experimental) |
| `/k9recall` | Calls your partnered K9 off whatever it's doing | Handler Partnership **and** Recall |

On a server where a feature has been switched back off, the matching
command usually doesn't exist at all — your game will say it doesn't
recognize the command, exactly as if you'd typed something made up.
`/k9calmdown` is the one exception: it always exists, but quietly does
nothing if Fear/Stress has been switched off.

### Staff-only and developer-only commands

You'll probably never be able to run these — they check for a special staff
permission, or (for `/k9bonetool`) are something server owners are told
never to turn on for regular play at all. Listed here only for
completeness.

| Command | What it does |
|---|---|
| `/k9auditcert [citizen id] [limit]` | Staff: look up someone's certification history |
| `/k9auditpartner [citizen id] [limit]` | Staff: look up partnership history |
| `/k9auditsearch <officer\|plate\|person\|recent> [value] [limit]` | Staff: look up search records |
| `/k9auditxp [citizen id]` | Staff: look up a K9's XP |
| `/k9auditdept [job] [limit]` | Staff: list everyone certified in a department |
| `/k9bonetool ...` | Developer tool for lining up cosmetic attachment points — never enabled on a real server |

---

## How this whole thing works

Two different players are usually involved:

- **The K9** — a player whose character already looks like a dog (a German
  Shepherd, Rottweiler, Husky, "Chop," or another dog model your server
  added). **Choosing to look like a dog is not something this resource
  does at all** — that happens through your server's normal
  character-creation or appearance system, before any of this. This
  resource only manages what a dog-looking character is *allowed to do*,
  and only after they're certified (see below).
- **The officer** — a regular department employee (police, sheriff, or a
  similar eligible job on your server) who works with the K9. The officer
  does **not** need to look like a dog and does **not** need their own K9
  certification to do most of the things in this guide.

A character can be both — nothing stops a supervisor from certifying
themselves if they also happen to be playing a dog.

---

## Becoming a K9 (certification)

Certification is what turns "a player who looks like a dog" into "a working
K9 the game actually treats as one." Without it, none of the K9-only
options below will appear for you.

### What you need before you can be certified

1. Your character must already be one of the dog models your server
   recognizes for this. By default that's a German Shepherd, Rottweiler,
   Husky, or Chop — your server may have added more.
2. You must be hired into a K9-eligible department. By default that's
   police, sheriff, or BCSO (Blaine County Sheriff) — your server may have
   changed this list.
3. A supervisor in that department has to certify you (see below). By
   default, a supervisor needs to be a department boss, or hold a high
   enough rank — exactly how high is set per department by your server.

### Getting certified

1. Stand close to the supervisor who will certify you — by default, within
   about 5 meters (roughly the length of a small car).
2. Either:
   - The supervisor **walks up to you and looks at you**, and an
     "ox_target" pop-up option called **Certify K9 Handler** appears for
     them to click, or
   - The supervisor types `/k9certify [your server ID]`.
3. If it works, you'll see **"You have been certified as a K9 handler."**
   and the supervisor sees **"Target has been certified as a K9
   handler."**

### What can go wrong (and what you'll see)

| Message | What it means |
|---|---|
| "Target is not playing a recognized K9 model." | You don't currently look like one of the dog models your server recognizes. |
| "Target is not employed by an eligible department." | Your job isn't one your server allows K9s in. |
| "Target already holds an active certification for this department." | You're already certified — nothing to do. |
| "Target is too far away to certify." | Get closer (see the distance above). |
| "Target must be online to be certified." | The person being certified has to be connected. |
| "You are not authorized to certify K9 handlers." | You (the one trying to certify) aren't ranked high enough, or aren't in an eligible department yourself. |
| "Self-certification is disabled on this server." | Some servers turn off certifying yourself; ask a supervisor instead. |

### Losing certification

A supervisor removes your certification the same two ways, in reverse:

- Walk up to the K9 and click **Revoke K9 Certification**, or
- Type `/k9decertify [server id]` if they're online.

If the K9 isn't online right now, use:

```
/k9decertifyoffline [citizen id] [job]
```

You'll need their **citizen ID** (their permanent character ID, not their
server ID) and the exact job name (e.g. `police`) — ask staff if you don't
have these.

Certification is also removed automatically and immediately if you quit
your K9-eligible job, or lose it for any other reason.

---

## Putting a leash on a K9 (on by default)

A leash keeps an officer and a K9 close together. Either side can start it,
and **either side can end it whenever they want, with no permission
needed** — nobody can be trapped on a leash.

### Attaching

1. Walk up to the other person (officer walks up to K9, or K9 walks up to
   officer — either works).
2. Click the **Attach Leash** option that pops up, or open the [radial
   menu](#the-k9-radial-menu) and pick **Attach/Detach Leash**.
3. The other player gets a pop-up window on their screen asking:
   **"[Your name] wants to attach a leash to you. Accept?"** with **Accept**
   and **Decline** buttons. Nothing happens until they click Accept.
4. Once accepted, you'll both see a message — the K9 sees **"You are now
   leashed."**, the officer sees **"You are now anchoring the leash."**

**Who counts as the K9 side:** whichever one of you is actually playing a
recognized dog model and is certified. If somehow both of you look like
dogs, whoever gets *asked* to accept ends up being the one on the leash.

### While leashed

The leashed K9 gets gently pulled back toward the officer if they wander
too far — by default this starts at around 6 meters and the leash snaps
completely (with the message **"Leash snapped — you got too far from your
handler."**) at around 12 meters. This is a soft pull, not a hard stop —
you can still move, just not indefinitely far from your partner.

### Detaching

Either person can end it at any time:

- Open the [radial menu](#the-k9-radial-menu) and pick **Attach/Detach
  Leash** again (it becomes "Detach" while leashed), or
- Type nothing — there's no dedicated detach command; use the radial menu.

You'll see **"Leash detached."** If your partner disconnects, you'll see
**"Leash detached — your partner disconnected."** instead.

### What can go wrong

| Message | What it means |
|---|---|
| "You are too far apart to attach a leash." | Get closer before requesting. |
| "One of you is already leashed to someone else." | One side is already leashed — detach first. |
| "Neither party is playing a recognized K9 model." | Neither of you currently looks like a dog. |
| "The K9 is not certified for K9 duty." | The dog-looking side hasn't been certified yet. |
| "The handler must be employed by an eligible department." | The officer side needs an eligible job — they do **not** need their own K9 certification. |
| "Your leash request was declined." | Exactly what it says. |

---

## The K9 Radial Menu (on by default)

This resource adds a **"K9 Unit"** icon into your server's regular radial
menu (the round pop-up wheel of quick actions). Open your radial menu the
same way you always do on this server, then click the K9 Unit icon to open
its own sub-menu.

**On a default server, that sub-menu only contains:**

- **Sit** — makes your dog character sit down. Works until you move again.
- **Bark** — makes your dog character bark (see the audio note below).
- **Attach/Detach Leash** — see the [leash section](#putting-a-leash-on-a-k9-on-by-default) above.
- **Enter/Exit Vehicle** — see [vehicles](#riding-in-a-patrol-vehicle-on-by-default) below.

Every other item described later in this guide (tracking, combat, fetch,
kennel, gear, and so on) only appears in this same menu **if your server
has turned that specific feature on.** If you don't see an option
mentioned below, it's switched off — not missing by mistake.

### About Bark's sound

Bark is turned on. As of when this guide was last checked, a
real, properly-licensed bark sound file has been added and is confirmed to
actually reach your game client, so a plain Bark should genuinely play a
sound. Three extra bark sounds used only by the "different bark
styles" feature (also turned on, along with everything else in this
resource — see the top of this guide) do not exist yet, so that specific
feature stays silent even though it's switched on. This resource is actively
being worked on by multiple people at once, so if Bark is ever silent for
you, that's worth reporting to your server's staff rather than assuming
it's expected — check `html/sounds/CREDITS.md` in this resource's files for
the current, up-to-date record of exactly which sounds exist.

---

## Riding in a patrol vehicle (on by default)

By default this works on marked police and sheriff cars (`police`,
`police2`, `police3`, `police4`, `sheriff`, `sheriff2` — your server may
have added more).

1. Walk up to one of those vehicles, within about 3 meters.
2. Click **Load K9 Into Vehicle**. Your character is hidden and tucked
   into the vehicle (so it can ride along without needing its own seat).
   You'll see **"Loaded into the vehicle."**
3. To get back out, either walk up to that same vehicle and click
   **Release K9 From Vehicle**, or use **Enter/Exit Vehicle** from the
   [radial menu](#the-k9-radial-menu). You'll see **"Released from the
   vehicle."**

If you try this while you're already sitting in a vehicle normally
(through the game's own controls, not this system), you'll see **"You
can't do that while already sitting in a vehicle."**

---

## Basic dog things (on by default)

These work automatically for anyone playing a recognized dog character —
you do **not** need to be certified for these three:

- **First/third-person camera** — press **L** to switch your camera
  between first-person (dog's-eye view) and third-person. You'll see a
  small confirmation message either way. This only works while you're
  playing a dog character.
- **Jump and crouch** — work exactly like they do for any other character.
  Nothing extra to learn. (If your server has turned this off, a dog
  character's jump and crouch stop working — but that isn't the default.)
- **Sit** — from the [radial menu](#the-k9-radial-menu), described above.
  This one *does* need certification.

---

## World interactions, at a glance (ox_target)

This table lists every "walk up and look at something" option this
resource can add. Every one of them is turned on as of this guide's last
check (2026-08-25) — the **Feature switch** column names which one your
server's staff could turn back off if you ever stop seeing an option
listed here.

| Walk up to... | Option you'll see | What it does | Feature switch |
|---|---|---|---|
| A nearby player | **Attach Leash** | Starts the leash consent request | Leash Mechanics |
| A nearby player who looks like a K9 | **Certify K9 Handler** | Certifies them (if you're a qualifying supervisor) | always available, no switch |
| A nearby player who looks like a K9 | **Revoke K9 Certification** | Removes their certification | always available, no switch |
| An eligible patrol vehicle | **Load K9 Into Vehicle** | Tucks you into the vehicle | Vehicle Entry/Exit |
| The vehicle you're tucked into | **Release K9 From Vehicle** | Lets you back out | Vehicle Entry/Exit |
| A door | **Scratch to Alert** | Plays a scratching sound to alert nearby people — cosmetic only | Door Interaction |
| A door | **Nudge Door** | Plays a push animation — this can **never** open a locked door, by design | Door Interaction |
| A vehicle | **Search Vehicle** | Sniffs it for contraband | Search Zones |
| A person | **Search Person** | Sniffs them for contraband | Search Zones |
| A nearby player | **Partner Up** | Sends a long-term partnership request (separate from a leash) | Handler Partnership |
| A deployed kennel | **Pick Up Kennel** | Picks the kennel back up | Deployable Kennel |
| A K9 player | **Pet K9** | Improves the K9's mood | Mood system |
| A K9 player | **Feed K9** | Improves the K9's mood using a treat item | Mood system |
| A K9 player | **Open K9 Gear** | Opens the K9's small item storage | K9 Inventory |
| A thrown fetch ball | **Pick Up Ball** | Picks up the ball | Fetch |
| A nearby player, while carrying a ball | **Deliver Fetch Item** | Delivers it to a handler | Fetch |
| A K9 player | **Treat K9** | Heals an injured K9 with a medkit item | K9 Medkit |

---

## The rest of what this resource can do

Everything from here down is **on by default** as of this guide's last
check (2026-08-25). Each heading names the feature switch it needs, so if
something below stops working, you know which switch to ask your server's
staff about — they may have turned that specific piece back off. If a
switch is off, you'll either not see the option at all, or (for a few
commands) typing it will do nothing.

### Searching people and vehicles — needs "Search Zones"

Once enabled, a certified K9 can walk up to a vehicle or person and click
**Search Vehicle** / **Search Person**. A short sniffing animation plays
(about 4 seconds by default), then one of these appears:

- **"Nothing found."** — clean.
- **"Contraband detected!"** — something was found. Depending on how much,
  nearby people may also hear a reaction sound (a soft whine for a small
  amount, an aggressive bark for a large stash).
- **"The search could not be completed — try again."** — a real error, not
  the same as "nothing found."

You can't repeat a search on the exact same target for a while afterward
(10 seconds by default) — this stops fishing for a different result by
searching the same thing over and over.

### Tracking scent, blood, or gunpowder — needs "Scent Tracking" / "Blood Tracking" / "Gunpowder Sniffing"

Each is its own switch. When on, the [radial menu](#the-k9-radial-menu)
gets a **Track Scent**, **Track Blood**, or **Track Gunpowder** item. As a
certified K9, picking one searches nearby (about 40 meters by default) for
something trackable — a dropped item for scent, a recent injury for blood,
recent gunfire for gunpowder — and if one is found, draws a visible trail
of markers toward it. Walking through water breaks the trail by default,
and you'd need to search again once across the water. Picking the same
item again while tracking stops the trail early.

### Combat actions — needs "Bite & Hold" / "Non-Lethal Takedown" / "Prop Dragging"

These let a certified K9 physically engage a target. Each is its own
switch, and all of them are restricted to targets your server's dispatch
system has flagged as **wanted** (this never applies to ordinary bystander
NPCs, only to marked suspects).

- **Bite & Hold / Release** (radial) — holds a nearby eligible target in
  place. Ends automatically after 15 seconds if nobody releases it sooner,
  so nothing can be held forever.
- **Non-Lethal Takedown** (radial) — only works on a target that's
  currently moving fast (fleeing). Knocks them down briefly.
- **Drag / Release** (radial) — drags a target along with the K9, up to
  30 meters or 20 seconds, whichever comes first.

You'll see messages like **"That target is not currently eligible."**,
**"You are too far from the target."**, or **"You must wait before
attempting that again."** if a request is rejected.

### Advanced agility (fence/window vaulting) — needs "Advanced Agility"

Press **X** as a certified K9 near a low obstacle (up to about 1.2 meters
by default) to hop over it. There's a short cooldown (2 seconds by
default) between attempts.

### Handler Partnership — needs "Handler Partnership"

This is a longer-term bond between one officer and one K9, separate from
the momentary leash above.

1. Walk up to the other player and click **Partner Up**, or use the
   [radial menu](#the-k9-radial-menu)'s **Partner Up** item.
2. They get an Accept/Decline pop-up, same style as a leash request:
   **"[Name] wants to partner up with you. Accept?"**
3. Once accepted, both sides see a confirmation message.

To end it, either side picks **Break Partnership** from the radial menu —
this always works immediately, with no confirmation needed, even if
something about your access has changed since.

**Handler-Down Defense** (needs Handler Partnership **and** its own
switch): if a partnered officer's health drops low near their partnered
K9, the K9 sees **"Your handler is under attack! Press G to respond, or
use the radial menu."** (the key is `G` by default). Confirming lets the
K9 respond against whoever the game thinks is responsible — this is a
faster way to bring up the same option a player could pick manually, not
the K9 acting on its own.

**Recall** (needs Handler Partnership **and** its own switch): the
partnered officer can type `/k9recall` or use the radial menu's **Recall
K9** item at any time to immediately call their K9 off whatever it's
doing — this always works, with no cooldown beyond a couple of seconds
between uses, specifically so a partner is never stuck.

### K9 wellbeing — needs its own switches (all on by default)

Five separate systems, each its own switch:

- **Mood** — walk up to a K9 and **Pet K9** (free) or **Feed K9** (needs a
  treat item) to improve their mood. Low mood slightly slows the K9 down.
- **Fatigue** — builds up while sprinting, recovers while resting (near a
  water bowl object, if your server has one placed). Low fatigue slightly
  slows the K9 down.
- **Fear/Stress** — rises from nearby gunfire. High stress makes the K9
  refuse combat actions temporarily ("Your K9 hesitates, too stressed to
  act."). The K9 can use `/k9calmdown` to reduce it themselves (a
  15-second cooldown applies).
- **Distraction** — `/k9meatbait` and `/k9whistle` are deliberately open
  to **any player**, not just K9s — a suspect being chased can use one of
  these items against the K9 following them.
- **Injury/Limping** — builds up from damage. Low values block sprinting
  or jumping entirely until treated. The main way to recover is a K9
  Medkit (below); it also recovers very slowly on its own.

### K9 Medkit — needs "K9 Medkit"

Walk up to an injured K9 and click **Treat K9** (requires a medkit item in
your own inventory, and typically requires being in an eligible department
or the ambulance service). There's a cooldown (1 minute by default) on
re-treating the same K9. You'll see **"K9 treated."** on success.

### K9 Gear (a small shared storage box) — needs "K9 Inventory"

Walk up to a K9 and click **Open K9 Gear** — this opens a small storage
container ("stash") tied to that specific K9, 5 slots by default. Anyone
in an eligible department can open a given K9's gear, not just that K9's
own player — think of it as shared department equipment, the same way a
patrol car's trunk usually works.

### Fetch — needs "Fetch"

1. An officer types `/k9throwfetchball` or uses the radial menu's **Fetch**
   submenu → **Throw/Drop Fetch Ball**. You don't need to currently be
   playing a dog to throw it.
2. A K9 walks up to the thrown ball and clicks **Pick Up Ball**.
3. The K9 walks up to a handler and clicks **Deliver Fetch Item** to hand
   it over.
4. The K9 can drop it early with `/k9dropfetchball`, and whoever threw it
   can cancel the whole thing early with `/k9recallfetchball`.

A ball disappears on its own after 5 minutes if nobody finishes the cycle.
Note that the K9 does not walk the ball back automatically — an actual
player has to carry it back, on foot.

### Deployable Kennel — needs "Deployable Kennel" (experimental)

A certified K9 can type `/k9deploykennel` or use the radial menu's
**Deploy Kennel** to place a portable kennel a couple of meters in front of
them. You can only have one deployed at a time — pick it up (**Pick Up
Kennel**, walking up to it) before deploying another. This feature is
flagged by its own developers as experimental — the object used to
represent the kennel may not look like an actual doghouse; if the intended
model fails to load, it falls back to an obviously-wrong placeholder shape
on purpose, as a signal to server staff that the real object still needs
fixing.

### K9 Vest — needs "Prop Attachments" (experimental)

A certified K9 can type `/k9propattach` or use the radial menu's **Toggle
K9 Vest** to put on or take off a cosmetic vest. Like the kennel above,
this is experimental — the intended vest model isn't confirmed to load
correctly, and may fall back to an obviously-wrong placeholder look.

### Thermal and night vision — needs "Thermal Vision" / "Night Vision"

Two independent switches. If turned on:

- **K** toggles thermal vision.
- **J** toggles night vision.

Unlike most K9-only actions, these work for **any player currently
playing a dog character**, even one who isn't certified — the reasoning
being that this is treated as the dog's own natural senses, not a granted
department privilege. Turning one on turns the other off automatically if
both were somehow active.

### XP and tiers — needs "XP Progression"

If turned on, a K9 quietly earns experience for real actions (finding
contraband, successfully tracking something down, and a few combat
actions, if those are also enabled). There are four tiers:

| Tier | XP needed | Bonus |
|---|---|---|
| Recruit K9 | 0 | none |
| Trained K9 | 1,250 | slightly faster, slightly better tracking range |
| Veteran K9 | 4,000 | more of the same |
| Elite K9 | 9,000 | the most of the same |

(Figures checked directly against `config.lua` on 2026-08-25 — these were
raised from an earlier 500/1,500/3,500 scale once measured play showed the
old numbers let a K9 reach the top tier in under an evening; re-check
`config.lua`'s `Config.XPTiers` yourself if it's been a while, since these
are tuning numbers a server can change.)

You'll see **"Your K9 has reached the [tier] tier!"** the moment you level
up. There's no command to check your XP as a player — only the staff-only
`/k9auditxp` command can look it up.

### Vitality display — needs "Health/Stamina HUD"

A small, passive on-screen display of your K9's health and stamina. It
just shows up in the corner of your screen if this is turned on — there's
nothing to click or press for it.

---

## Contraband screen effect — needs "Contraband Screen FX" (and Search Zones)

If both of these are on, finding a large stash during a search gives
*your own* screen (the searching K9's) a brief, disorienting visual effect
— a few seconds long. This is meant as feedback to you, not a penalty
applied to whoever you searched.

---

## Common messages you might see anywhere

| Message | What it means |
|---|---|
| "You cannot use K9 features right now." | You're either not playing a recognized dog character, not certified, or both. |
| "This only works while playing a K9 character." | Applies to camera/vision toggles — you need to look like a dog right now. |
| "That player is no longer online." | Whoever you targeted disconnected before your action went through. |
| "Get closer to the K9 first." | Move closer and try again. |
| (No message at all) | Some actions are deliberately silent when you retry too quickly — this is intentional spam prevention, not a bug. |

---

## A note on fairness and safety

A few design choices worth knowing about, since they affect what you can
rely on:

- **You can never be permanently trapped.** Leashes, bite holds, drags, and
  partnerships can always be ended by at least one side, and several have
  hard time limits even if nobody acts (a bite hold ends by itself after
  15 seconds no matter what).
- **Combat actions only ever target players your server's own dispatch
  system has marked "wanted."** An ordinary bystander can't be targeted
  by Bite & Hold, Takedown, or Dragging.
- **Distraction items (meat bait, whistle) are deliberately open to
  everyone**, including someone actively being chased — this is by
  design, not an oversight.
