# K9 Ideas — Making It More Fun (and a Little More Powerful)

This is a plain-language list of ideas to make **playing the dog** better. Not
running a K9 script that controls an NPC dog — actually being the dog,
which is what this add-on already does. That matters, and it shaped
everything below.

## Read this bit first — it explains why some ideas you'll see elsewhere don't apply here

Almost every K9 add-on people talk about online — for GTA, and for most
other games too — is built around an officer **commanding** a dog that the
computer controls. The officer presses a button, the computer-controlled dog
runs over and does a trick. I checked a few of the most talked-about FiveM
K9 scripts directly, including one literally named "player controlled K9,"
and every single one of them turned out to be the officer-commands-a-robot-dog
kind, not the be-the-dog kind.

Your server is not that. A real person plays the dog, the same way a real
person plays every other character. That's rare, and it means most of what
gets written about "K9 features" for other servers is answering a different
question than the one you're asking. I've thrown out ideas that only make
sense for a computer-controlled dog, and kept the ones that are actually
about what a *player* pretending to be a dog would do, see, and feel.

## What I looked at before writing any of this down

**Real police dog work.** Real K9s search buildings for a hidden person,
search open ground for a missing hiker or dropped evidence, follow a scent
trail, and get called in on people who are already flagged as suspects — not
random bystanders. All of that is richer and more interesting than anything
I could invent from scratch, so most of the ideas below are just "make the
game let you do the real job," not made-up mechanics.

**Other games where you play an animal.** A few things came up again and
again in how critics and players describe what works and what doesn't:

- The best animal games (a fox game called *Spirit of the North* is the
  clearest example) don't rely on combat or a story with lots of talking.
  They work because moving around and using your senses simply *feels*
  good. When the movement feels stiff, players notice immediately and it
  drags the whole game down — so if any of the ideas below get built, how
  they *feel* to move and sense the world in needs real testing, not just
  a "does it technically work" check.
- Games that give you a "special sense" (Batman's detective vision, The
  Witcher's tracking sense) got criticized when they turned into "just
  press a button and everything useful in the world lights up on screen."
  The lesson: a dog's nose should feel like a real sense you're using —
  sound getting louder, a growl, a head-turn — not a menu that hands you
  the answer.
- A game about playing wild/stray animals (*Tokyo Jungle*) got criticized
  because players often couldn't tell what their character could actually
  smell or hear, or from how far away. Whatever "sense" gameplay gets
  built here needs to be clear and readable, or it'll frustrate people
  instead of feeling cool.

**What's actually possible in this game engine right now.** I checked what
this specific add-on already does today, and it already proves out the two
hardest technical pieces the ideas below need: it already plays a sound that
gets louder or quieter depending on how close you are to something (used for
the "you can hear a nearby K9" ambient effect), and it already flashes a
short visual effect on one specific player's own screen when something
happens (used for the "you just found a big stash" effect). Both of those
are exactly the building blocks a "smell your way toward something" feature
would need — this isn't a new invention, it's pointing existing tools at a
new job.

---

## The ideas, best value first

For each one: what you'd actually experience, why it should be fun, how big
a job it looks like, and what to watch out for.

### 1. Make finds feel like a real alert, not a pop-up message

**What you'd experience:** Right now, when your dog finds contraband or
reaches the end of a scent trail, you get a little text message on screen —
"Contraband detected!" That's it. Instead, the dog itself should react: sit
down and bark on its own, the way a real detection dog does when it finds
something ("the trained final response," it's actually called — a real dog
doesn't tell its handler in words, it *shows* them). The bark sound this
add-on already made should change depending on what happened — a sharp
alert bark for a big find, a small whine for nothing found, and so on.

**Why it'd be fun:** It's the cheapest way to make the dog feel like an
actual working animal instead of a menu you click. You already have every
piece needed — sitting, barking, and even three different bark sounds
already exist in this add-on. This idea is just "use them automatically at
the right moment" instead of "only when a player manually clicks a bark
button."

**How big a job:** Small. Nothing new needs to be built — existing sit and
bark actions just need to be triggered automatically at the moment a search
or a track finishes, instead of only ever happening because a player
clicked something.

**Watch out for:** Basically nothing to worry about here — it doesn't
change anyone's rights, powers, or ability to abuse anything. The only real
risk is doing it so often it gets annoying (a bark on every single tiny
event) rather than only on things that matter.

---

### 2. "Follow your nose" — turn searching into an actual hunt, not a single click

**What you'd experience:** Today, if you want to search for contraband, you
have to already know exactly which car or which person to walk up to and
click. That's fine for a quick roadside stop, but it's not what a real
building search or area search feels like. Imagine instead: your handler
sets up a search area — "somewhere in this house" or "somewhere in this
yard" — and you, playing the dog, don't get told where the thing is. You
just start sniffing around. As you get closer to whatever's hidden, a low
growl or panting sound gets a little louder, or your view tints slightly.
Get further away, and it fades. You're not reading an answer, you're
hunting for one, the way a real search dog actually works a building —
ranging back and forth, getting more excited as it closes in, until it
finally alerts right on top of the hiding spot.

**Why it'd be fun:** This is the single closest thing on this whole list to
"real K9 building/area search," which is genuinely one of the most common
things real police dogs are used for. It also directly answers the "senses
should feel like senses, not a menu" lesson above — you're not told the
answer, you're guided toward it by something that feels physical.

**How big a job:** Medium. It's not a small tweak — it needs a way to mark a
search area, a hidden spot inside it, and a getting-warmer/colder effect
that updates as you move. But the actual sound-gets-louder-as-you-get-closer
trick is already proven inside this add-on for something else (the ambient
"there's a K9 nearby" sound already does exactly this), so it's re-using a
tool this project already built and trusts, not inventing a brand-new one.

**Watch out for:** This is the idea on this list that most needs an actual
in-game test before anyone counts on it. "Sound gets louder as you get
closer" sounds simple to describe but is easy to get wrong in practice — if
the feedback is too subtle, players won't notice it; too strong, and it's
just an alarm, not a sense. Budget time to actually play with it and adjust
before treating it as finished. This idea doesn't touch other players' rights
or abilities, so there's no fairness risk here — the only risk is "it doesn't
feel as good as it sounds on paper" until it's been tuned.

---

### 3. Missing-person and search-and-rescue calls

**What you'd experience:** Not every call needs a suspect. Real K9 units
spend real time finding lost hikers, missing kids, and lost property — calls
where nobody's in trouble and nothing bad happens at the end, just a good
outcome. This would be the same "follow your nose" hunting feeling from
idea #2, but the thing you're looking for is a lost hiker NPC or a piece of
lost property, and finding it plays out as a rescue, not an arrest.

**Why it'd be fun:** It's a genuine change of pace. Everything else in this
list — and most of what already exists in this add-on — revolves around
chasing or catching someone. This gives players something to do that feels
good for a completely different reason: nobody has to be a "bad guy" for the
call to matter. It's also realistic — this is genuinely one of the things
real K9s are used for most often, alongside suspect work.

**How big a job:** Medium, but cheaper than it sounds, because it's really
just idea #2's hunting feeling, pointed at a different kind of call. Most of
the actual work is deciding what a "rescue" looks like when the dog finds
the target, not building new tracking tools from scratch.

**Watch out for:** Nothing about fairness or abuse — no other real player
loses anything or gets restrained. The only thing to decide up front is
whether the "missing person" is always a computer-controlled character, or
could ever be a real player who agreed to hide — if it's ever a real player,
make sure it stays something they opted into, not something that can be
pointed at someone who didn't agree to it.

---

### 4. Scent lineup — "sniff the row and pick the match"

**What you'd experience:** A real (if imperfect — more on that below)
technique real police dog units actually use: a dog sniffs something from a
crime scene, then walks past a line of several people, and reacts most
strongly to the one whose scent matches. Translate that here: an officer
lines a few players up, your dog sniffs an item first (the same "sniff an
item to start tracking" action this add-on already has), then walks along
the line. Standing near the real match should feel different — the growl
gets sharp, maybe your dog stops and sits on its own (reusing idea #1's
"real alert") — while walking past everyone else feels like nothing.

**Why it'd be fun:** It's a genuinely different multiplayer moment — a whole
little scene involving several players standing in a row while everyone
watches the dog work its way down the line. Nothing else on this list, or
in the add-on today, creates that kind of shared, tense little moment.

**A fact worth knowing honestly:** real "scent lineups" are actually
controversial among real forensic scientists — dogs get it wrong more often
than courts used to assume, and several countries have stopped treating it
as reliable evidence on its own. That doesn't matter for a game (nobody's
going to prison off a make-believe dog's make-believe nose), but it's worth
knowing this isn't quite the slam-dunk "proven police technique" it might
sound like — it's a real thing police dogs are asked to do, with real,
documented doubts about how well it actually works even for real dogs.

**How big a job:** Medium. It needs: a way to remember which specific person
your dog's most recent "sniff" was actually tied to, a way for an officer to
line several players up, and a "sniff this specific person" action for each
one in the line that compares against what was remembered. It reuses the
same "an item is tied to a specific person's scent" idea this add-on
already uses for scent tracking — it's a new arrangement of an existing
idea, not a new kind of idea.

**Watch out for:** Make sure standing in the "lineup" is something a player
has to agree to, the same way this add-on already requires people to accept
a leash request before it does anything to them — nobody should be forced
into a lineup against their will.

---

### 5. Pursuit sprint — a short burst of "the dog is genuinely faster than you"

**What you'd experience:** This is the direct answer to "make it feel more
powerful." Right now, chasing someone on foot as a dog probably feels about
the same as chasing someone as a human, which doesn't match reality —
police dogs are dramatically faster than a sprinting person over a short
distance, and that's exactly why they're used to run suspects down. This
would give a certified K9, only while actually chasing someone your
server's own system has already flagged as a suspect, a short burst of real
extra speed — a few seconds of "I am actually catching up to you now,"
on a cooldown so it can't be used constantly.

**Why it'd be fun:** It's the one moment on this whole list that's purely
about *feeling powerful*, which is exactly what was asked for — and it does
it the safest possible way: it only makes the dog move faster. It doesn't
touch what happens once you catch someone (this add-on already has
bite-and-hold, takedowns, and dragging for that, and — worth being blunt
about — this project's own documentation already says there are two
unresolved safety questions about how fair and cheat-proof those existing
combat features are). This idea deliberately stays away from all of that
and only ever makes the chase itself feel exciting, not the outcome once
someone's caught.

**How big a job:** Small — this is a case of turning on a speed boost for a
few seconds, gated the same way other combat-adjacent features already are
(only against a flagged suspect, only for certified K9s, with a cooldown).

**Watch out for two real things, honestly:**
- **Fairness:** stacking a genuinely faster dog on top of the existing hold
  and drag mechanics could make it close to impossible for anyone to ever
  get away from a K9 at all. Given that this server has already had to shut
  down eight XP farms for being more exploitable than they first looked,
  this deserves an actual conversation about numbers (how long the burst
  lasts, how long the cooldown is, whether it should have a limited number
  of uses per chase) before it ships — not because the idea is bad, but
  because "how much faster, for how long" is exactly the kind of number
  that looks fine on paper and turns out to feel awful in practice.
- **Whether it even works cleanly:** I found one specific, second-hand
  report online (a single forum discussion, not something I could verify
  myself) that speed-changing commands in this engine behave inconsistently
  across different dog character models — working fine on one specific
  default dog character, but not reliably on others. This add-on supports
  several dog breeds by default, not just one, so this needs an actual
  in-game test across every breed your server allows before anyone assumes
  it'll just work everywhere.

---

## An idea I looked at and am **not** recommending: crowd-control barking

Real police dogs have historically been used to intimidate and disperse
crowds — bark and lunge at a line of people to make them back off. I looked
into this seriously since it's real police procedure, but I'm not
recommending it, for two honest reasons:

1. **The real-world history here is genuinely dark, not just old-fashioned.**
   Police dogs being set on crowds is one of the most infamous, painful
   images from the civil rights era in the US, and several real
   jurisdictions have since banned using police dogs this way entirely. I
   don't think "make players feel what that felt like" is a good goal for
   this add-on, even in fiction.
2. **It doesn't actually clear the game-design bar either.** For it to do
   anything mechanically, it would need to affect other players who never
   agreed to it — the exact kind of "my dog affects your character without
   your consent" pattern this add-on's own documentation already flags as
   its riskiest, least-resolved area (the existing bite-and-hold and
   takedown features). Adding a new way to affect people who didn't opt in,
   on top of ones that are already flagged as not fully sorted out, isn't
   worth it for what would mostly be a cosmetic effect.

Recording this here so nobody spends time re-researching it later expecting
a different answer.

---

## Honesty check — what's solid vs. what needs testing

- Ideas #1 and #5 (real alerts, pursuit sprint) reuse things this add-on
  already proves work today. The main open question on #5 is the numbers
  (how strong, how often) and whether it behaves the same on every dog
  breed — not whether the idea works at all.
- Ideas #2, #3, and #4 (follow your nose, missing persons, scent lineup) are
  all genuinely new systems. The core trick they all lean on — sound or
  screen effects that scale with distance or match a hidden condition — is
  proven inside this add-on already, but exactly how *good* it feels in
  each new situation is something nobody will know for certain until it's
  actually built and played, not just designed on paper. Budget real
  playtesting time for these, especially #2.
- None of the five recommended ideas require any other server system (no
  specific dispatch, no specific ambulance mod, nothing named). If any of
  them gets built and your server doesn't run some extra system, it should
  just work on its own with nothing missing — and if a later version wants
  to *also* hook into whatever dispatch or record system your server
  already runs, that should be an optional bonus on top, never something
  the feature breaks without.

---

## If you only do three things

1. **#1 — Real alerts.** It's nearly free, makes the dog feel alive
   immediately, and touches nothing risky.
2. **#2 — Follow your nose.** The single biggest upgrade to how it *feels*
   to actually be the dog doing real detection work, built from tools this
   add-on already has proven working.
3. **#5 — Pursuit sprint.** The actual answer to "more powerful," done in
   the one place (speed, not combat) where making the dog stronger doesn't
   also make the game less fair for the person being chased — as long as
   the numbers get a real balance pass first, and it gets tested on every
   dog breed before going live.

---

## Sources

Real police K9 procedure:
- [Inside a Police K9 Unit: Selection, Training & Deployment](https://ppak9.org/blog/how-us-police-departments-select-train-deploy-k9-units/)
- [K-9 Unit — Constable Pct4](https://www.constablepct4.com/k-9-unit.html) (building search, missing persons, evidence recovery)
- [What Is a K-9 Unit? Police Dogs, Roles, and the Law](https://legalclarity.org/what-is-a-k-9-unit-and-what-are-their-key-roles/)
- [Enforce Logic — What Do Police Dog Search Units Do?](https://enforce-logic.com/blogs/what-do-police-dog-search-units-do)
- [City of Madison Police Department SOP — K9 Use](https://www.cityofmadison.com/police/documents/sop/K9Use.pdf)

Scent lineups (real technique, real controversy):
- [ScienceDirect — Scent lineups compared across eleven countries](https://www.sciencedirect.com/science/article/abs/pii/S0379073819303081)
- [Animal Legal & Historical Center — Scent Identification Procedures](https://www.animallaw.info/article/scent-identification-procedures-us-have-different-history-and-different-procedures-those)
- [LLRX — Canine Detection Evidence](https://www.llrx.com/2010/09/canine-detection-evidence/)

Crowd control (why I didn't recommend it):
- [K9 Deterrent and Crowd Control — TacticalK9USA](https://www.tacticalk9usa.com/k9-deterrent-and-crowd-control-recently-posted0/)
- [A Brief History of K-9 Units in Law Enforcement](https://www.criminallegalnews.org/news/2023/mar/16/brief-history-k-9-units-law-enforcement/)
- [CBS News — bill to ban police dogs for crowd control](https://www.cbsnews.com/sacramento/news/bill-to-ban-police-from-using-a-k9-for-crowd-control-moves-to-the-assembly-appropriations-committee)

Other games playing as an animal:
- [Nintendo Life — Spirit of the North review](https://www.nintendolife.com/reviews/switch-eshop/spirit_of_the_north)
- [Gamecritics — Spirit of the North review](https://gamecritics.com/david-bakker/spirit-of-the-north-review/)
- [Game Developer — Making It Better: Tokyo Jungle](https://www.gamedeveloper.com/design/making-it-better-tokyo-jungle)
- [Witcher Senses — Witcher Wiki](https://witcher.fandom.com/wiki/Witcher_Senses)
- [TheGamer — CD Projekt Red admits Witcher Sense was overused](https://www.thegamer.com/the-witcher-3-wild-hunt-cd-projekt-red-admits-it-overused-witcher-sense-detective-vision-mechanic-defense/)

What's actually possible in this engine (checked against this add-on's own
existing, already-working code, and against official native documentation):
- [Cfx docs — SetRunSprintMultiplierForPlayer](https://docs.fivem.net/natives/?_0x60BF608F1B8CD1B6=)
- [citizenfx/natives — SetPedMoveRateOverride](https://github.com/citizenfx/natives/blob/master/PED/SetPedMoveRateOverride.md)
- A community forum thread reporting inconsistent dog-ped speed behavior
  across different dog models was found but could not be independently
  fetched/verified this session — treat the pursuit-sprint cross-breed
  concern in idea #5 as a real, testable question, not a confirmed bug.
- This add-on's own `client/proximityaudio.lua` / `client/audio.lua`
  (distance-scaled sound, already shipping) and `client/screenfx.lua`
  (single-player screen effect on a specific event, already shipping) are
  the two existing pieces that prove ideas #2–#4's core trick already works
  in this exact codebase.

Other FiveM K9 scripts checked (confirmed to be officer-commands-an-NPC
style, not player-controlled, despite one being named otherwise):
- [Virgildev/v-k9 on GitHub](https://github.com/Virgildev/v-k9)
