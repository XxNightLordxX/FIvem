# Changelog

What changed, in the order it changed, written for the person running the
server rather than the person who wrote the code.

This file covers **what you would notice**. It is not a commit log — there
are several hundred commits behind the entries below and most of them are
internal. For why a decision was made, see `PROJECT_HISTORY.md`; for what
is still wrong, see `KNOWN_ISSUES.md`.

Version numbers follow [semantic versioning](https://semver.org) and match
the `version` field in `fxmanifest.lua`. A **breaking change** means one
that needs you to do something — edit your config, import SQL, or change
how your staff work. Those are always called out under their own heading,
never buried in a list.

---

## Unreleased

**The version in `fxmanifest.lua` has never moved off `0.1.0`.** Nothing
here has been through a numbered release yet, so everything below is
"since the beginning" rather than "since the last version". The first
tagged release will draw a line under this section.

### Fixed — things that were broken for players

- **A certified dog was invisible.** Changing to a dog model gives you a
  new body with none of its parts switched on. A human survives that; a
  dog does not, because every part of the dog is one of those parts. Nobody
  had told the new body to use its own defaults, so it drew nothing at all
  — solid, targetable, and invisible to everyone including the player.
- **The bark on a contraband find never played, on any install.** The
  setting named a sound one way round and the shipped file was named the
  other. An unknown sound is ignored rather than reported, so nobody ever
  found out.
- **A dog could be teleported across the map inside a kennel.** Anyone can
  climb into a deployed kennel for a ride, and picking a kennel up brings
  whatever is inside along with it — but your own kennel could be picked up
  from any distance, because before dogs could ride in them there was
  nothing inside to move. An occupied kennel now has to be walked to.
- **Being dragged could not be ended by the person being dragged.** The
  server always accepted it; the key they would press asked "am I the dog
  doing the dragging", got no, and told them they were not certified for K9
  duty. The way out existed and could not be reached from anywhere.
- **Two dogs could be put in the same seat of the same car.** Each player's
  game picked a seat and checked only its own copy of the world.
- **A specialization could land on somebody who had just been decertified**,
  leaving a record that silently came back to life if they were ever
  certified again.
- **Switching XP progression off left the speed bonus running** for every
  dog already on duty until they reconnected.

### Changed — things that behave differently now

- **Dragging has cooldowns.** It had none, per-dog or per-person, while the
  documentation said it had both. The per-person one matters most: without
  it, letting go bought you nothing, because the dog could grab you again
  the same second.
- **The contraband alert's loudest tier now takes a genuinely large find.**
  It triggered at 250 weight; a single handgun is about a thousand. One gun
  and a car boot full of drugs produced the same alert.
- **Barking and door-scratching now reach people within 300 metres**
  instead of every player on the server. If the distance check is ever
  unavailable it falls back to telling everyone, because a bark you cannot
  hear is worse than the waste.
- **Handler ranks are reachable.** The first rank needed 750 XP; a handler
  who does not personally certify others can earn at most 155, ever. So
  most handlers could never leave the bottom rung at any number of hours.
  Now 50 / 150 / 500.
- **Handlers can see their own rank and XP.** It was tracked, it shortened
  their cooldowns, and nothing ever told them it existed.
- **A dog cannot search while it is in a car or already holding somebody**,
  and cannot start a bite, takedown or drag while a search is running.
  Both were previously refused only on the player's own machine.
- **Scent vision's off switch is a rule, not a request.** With it off, the
  server no longer answers the question at all.

### Added

- **Someone granted a single permission can now use it.** Granting only
  "may certify" left that person with no way to reach a person's record —
  the permission was real everywhere except the screen they would use it
  on, and the help text sent them to two tabs they could not see.
- **High command can make a dog's stamina last longer, or never run out.**
- **The startup log names which of your `config.lua` edits are being
  overridden** by a change made from the tablet, instead of printing a
  count. A setting changed on the tablet keeps winning over the file until
  it is reset there — correct, deliberate, and previously invisible.
- **Every combat setting says which way makes the dog stronger.** Two of
  them are counter-intuitive: lowering a cooldown makes the dog stronger,
  and the "maximum duration" settings are rare-case ceilings that look like
  they do nothing.

### Known limitations recorded rather than fixed

- The top handler rank cannot be reached without personally certifying
  other people, because certifying is the only paying action above the
  tenure ceiling. Fixing it needs the two unwired actions to start paying,
  which needs anti-farm protection built for them first.
- Two officers cannot work one search-and-rescue call together. The whole
  mechanic belongs to the officer who started it.
- `html/images/logo.png` is still a placeholder.

See `KNOWN_ISSUES.md` for the full list, including the ones that are
deliberate.

---

## 0.1.0

Not yet released.
