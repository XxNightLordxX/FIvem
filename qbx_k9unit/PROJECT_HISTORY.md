# Project History

A condensed record of how `qbx_k9unit` got to its current state, for
whoever works on this codebase next. This is not the bug list (see
`KNOWN_ISSUES.md`) and not the technical reference (see
`DEVELOPER_REFERENCE.md` for internals, `README.md` for install/config).
It exists so a real lesson learned along the way — a footgun found, an
exploit closed, an idea considered and rejected — isn't lost, without
requiring anyone to read a multi-thousand-line, commit-by-commit log to
find it.

If something below disagrees with the current code or config, the code
wins — this is a history, not a second copy of current behavior.

---

## What shipped

The resource was built in five rough stages, each adding an independently
toggleable feature set on top of the last. Every feature still ships
behind its own `Config.Features.*` flag; all of them currently ship `true`
in the default config (see `README.md` for the current, authoritative
list and any operator action that implies).

**Foundation.** A player's own persistent K9-model character, certified by
a qualifying officer per department, with a real, server-authoritative
access check on every gated action. A consensual two-player leash system,
a radial menu for self-actions (bark, sit, leash, vehicle load), and a
first/third-person camera toggle. Certification lives in its own database
table (not just character metadata) so it survives reconnects, supports
an audit trail, and is automatically revoked the moment someone leaves an
eligible department.

**Tracking and search.** Scent, blood, and gunpowder trail tracking, each
rendering a ground trail that degrades realistically at water crossings.
Contraband search of a vehicle or person, with a real server-side
inventory read (never a client-reported claim), tiered bystander alerts,
and a full search audit log. Thermal and night vision, toggled as the K9's
own innate perception rather than a granted permission. Door interaction:
a cosmetic scratch-to-alert, and a nudge-open that never touches real lock
state (there's no reliable, generic way to query an arbitrary door-lock
resource's state, so nudge-open is deliberately cosmetic-only, gated to
already-unlocked doors).

**Combat and action.** Bite & Hold, Non-Lethal Takedown, and Prop
Dragging — all three can target a player, not just an NPC, subject to a
wanted/suspect gate. This was a deliberate, informed decision, not an
oversight: no other FiveM K9 script surveyed had built player-vs-player K9
combat before, so there was no ecosystem precedent to lean on. Because a
live player's own client is the only thing that can actually apply certain
restrictive effects to itself (there's no way for the server or another
player to force a specific ragdoll/speed-limit/damage-suppression state
onto someone else's client), these three mechanics are honest about being
detection-and-log against a non-cooperating target, never a guaranteed
restraint — see `DEVELOPER_REFERENCE.md` §12.0 item 8 for the full
reasoning. Handler-Down Defense streamlines targeting when a partnered
handler takes damage nearby (the K9 player still confirms and controls
their own actions — this is a UI convenience, never an AI takeover).
Recall lets a handler unconditionally call their K9 off any of the three
mechanics, deliberately without a certification check on either side,
because an escape hatch must never depend on the same permission it might
be recalling someone out of. A DB-backed handler/K9 partnership registry
(mutual consent, survives a restart) underlies both Recall and
Handler-Down Defense.

**Inventory, progression, and wellbeing.** A K9's own `ox_inventory` gear
stash. Server-authoritative XP with tiered speed/scent bonuses. A unified
wellbeing subsystem (Fatigue, Mood, Fear/Stress, Distraction, Injury) — one
shared stat store and tick loop, each stat independently toggleable, all
five feeding one shared client-side "move-rate composer" so they can't
silently overwrite each other's speed effects. A K9 medkit. A contraband
screen effect for the searching officer.

**Audio, props, and polish.** An expanded bark radial (alert/aggressive/
calm variants), proximity-scaled growl audio, cosmetic prop attachments
(vest/harness) via a one-time bone-index sweep tool, a fetch-the-ball
mechanic, and a deployable kennel. A true picture-in-picture partner
camera feed was investigated and found genuinely impossible with FiveM's
current natives (DUI/NUI textures render HTML, not the 3D scene); what
shipped instead is a full-screen switch to your active partner's own
viewpoint, which is a real, working feature, not a placeholder.

**Later additions, after all five stages had landed:** certification
tiers with real, enforceable capabilities (not just labels); per-person
feature blocking widened from nine features to most of the resource;
a compatibility/adapter layer so targeting and inventory auto-detect the
host server's scripts (see `KNOWN_ISSUES.md` for why this does *not*
extend to the underlying framework); several tablet screens (a
permission-key catalog editor, an XP-rank editor, an equipment shop
location manager, and a read-only audit trail viewer); and a pass that
switched every feature flag from its cautious `false` default to `true`,
at the owner's request, once each feature had been reviewed.

---

## Security and economy hardening

A resource with an in-game economy attracts farming attempts, and several
were found and closed during development — recorded here because the
*pattern* is worth knowing even where the specific numbers aren't:

- Several XP-farming loops were found and closed: reusing a single logged
  scent/blood/gunpowder source instead of requiring travel time, forging a
  fresh scent source by dropping and picking an item back up, re-taking
  the same Bite & Hold target the instant its cooldown cleared, and two
  separate ways to make a contraband search pay out repeatedly for a
  stash whose actual contents never changed. Each is now rationed by a
  cooldown or a "did this genuinely change" check, applied at the exact
  point XP is minted rather than somewhere upstream of it.
- A family of natives that are real and correct on the client, but simply
  don't exist on the FiveM server, were being called server-side and
  silently no-op'ing — meaning code that looked correct had been doing
  nothing since it shipped (a kennel's spawn offset, a fetch ball's throw
  force, several death checks, and a damage-suppression backstop). None
  of these were security holes; they were quiet correctness bugs, found
  by writing tests that check the *actual resulting state*, not just that
  a function was called.
- A certification-grant race, a partnership-establishment race, and a
  contraband-search race were each closed with the same shape of fix: a
  short-lived in-memory lock around the whole check-then-write sequence,
  on top of (not instead of) a database-level uniqueness constraint as
  the real backstop.
- Several "client proposes, server confirms" handshakes (fetch, kennel
  placement, prop attachment) had branches where a confirmation could be
  rejected without ever telling the client to clean up its own copy of
  the object it had already created — leaving real networked objects
  orphaned. Fixed with a shared rejection path that always pairs a
  server-side refusal with a client-side cleanup instruction.

The recurring lesson across all of these: a security or economy review
that only reads the code for what it's *supposed* to do will miss a bug
where the code does something else entirely. Everything above was found
by either tracing an actual call site to its real, current native
behavior, or by writing a test that exercises the real code path
end-to-end and checking its real output.

---

## Documentation

This resource's documentation went through two rounds of consolidation.
The first collapsed roughly twenty overlapping design/spec/status
documents down to nine (a developer reference, an operator runbook, a
player guide, a README, a changelog, an issues list, a watchdog log, an
ideas backlog, and this history). The second — reflected in what you're
reading now — went further: everything genuinely aimed at a buyer, an
operator, or a player lives in `README.md`; everything a developer
inheriting the code needs lives in `DEVELOPER_REFERENCE.md`; every open
bug, limitation, and owner decision lives in `KNOWN_ISSUES.md`; and the
narrative of how the project got here lives in this file. Nothing that
existed only to help a team of contributors keep track of their own work
in progress made the cut.

### A note on the commit history

For a stretch of this project's development, work was done by many
contributors editing one shared checkout at the same time. A batch of
commits from that period describe their own changes less precisely than
they should — not because anything shipped broken (every commit in that
run parses cleanly and passes the full lint/test suite on its own, in
isolation), but because a commit made with a broad "stage everything"
habit can end up carrying a second contributor's unrelated, half-finished
work along with the one change its message actually describes. If you're
trying to work out exactly which commit introduced a specific line,
`git log -p` or `git blame` against the actual diff is more reliable than
trusting an old commit message's summary. The habit that caused this has
since been corrected (each contributor's changes are staged into an
isolated, private index before committing, so one commit can no longer
silently absorb another's work).

---

## Ideas considered, not built

A backlog of gameplay ideas aimed specifically at what makes *playing the
dog* better — not the more common "officer commands a computer-controlled
dog" style of K9 script, which this resource deliberately isn't. Kept here
as a roadmap for anyone deciding what to build next, not as a promise that
any of it is coming.

Ranked roughly by value for the effort involved:

1. **Real alerts instead of a pop-up.** When a search or a trail resolves,
   have the dog itself sit and bark (the "trained final response" a real
   detection dog gives), reusing sounds and actions this resource already
   has, rather than a plain text notification. Cheap, and touches nothing
   risky.
2. **"Follow your nose."** Turn a search into an actual hunt: the handler
   marks an area, and the K9 player gets warmer/colder audio-visual
   feedback while searching it themselves, instead of clicking one known
   target. The closest thing on this list to how a real K9 building search
   actually feels. Reuses the same proximity-scaled-audio technique this
   resource already ships for the "nearby K9" ambient effect. Needs real
   in-game tuning before it's trustworthy — "sound gets louder as you get
   closer" is easy to get wrong in practice.
3. **Missing-person / search-and-rescue calls.** The same hunting feeling
   as above, aimed at a lost hiker or lost property instead of a suspect —
   a genuine change of pace from the arrest-focused loop everything else
   in this resource centers on.
4. **Scent lineup.** A real (if genuinely controversial among actual
   forensic scientists — worth knowing, not a reason to avoid it in a
   game) K9 technique: sniff an item, then walk a line of consenting
   players and react distinctly to the one whose scent matches. A
   distinctive shared multiplayer moment; needs consent from anyone
   standing in the line, the same way leashing already requires consent.
5. **Pursuit sprint.** A short, cooldown-gated burst of real extra speed
   for a certified K9 actively chasing a flagged suspect — the most
   direct answer to "make the dog feel more powerful," and the safest
   place to do it, since it only ever affects the chase itself, never what
   happens once someone's caught. Needs a real balance pass (stacking a
   faster dog on top of existing hold/drag mechanics could make escape
   very hard) and testing across every dog breed this resource supports,
   since third-party reports suggest speed-override natives don't
   necessarily behave identically across different ped models.

**Considered and deliberately not recommended: crowd-control barking**
(a real, historical police K9 use — bark/lunge at a crowd to disperse it).
Left off this list for two reasons: the real-world history behind it is
genuinely dark, not just old-fashioned, and it doesn't clear the design
bar either — it would need to affect other players who never consented to
it, the same pattern this resource already treats as its riskiest,
least-resolved area in the existing combat features.

None of the five recommended ideas require any other specific server
resource to exist — dispatch/record-system integration, if ever added,
should be an optional bonus layered on top, not something the feature
breaks without. The original research notes (real K9 procedure, other
"play as an animal" games, and the specific natives involved) cited a
number of external sources; they're preserved in this file's git history
if anyone wants to revisit them, rather than reproduced here.
