# Dependency maintenance status + bark-audio gap — resolution pass

Author: technology-scout pass, 2026-08-24, jlwood17190665@gmail.com.

Purpose: close out the two externally-uncertain facts carried unresolved
across `WATCHDOG_LOG.md` Pass #4 and Pass #5 — (1) Overextended/CommunityOx
dependency maintenance status, (2) the practical next step on the bark-audio
asset gap (`SPEC.md` §7, `phase2_notes/phase5_features_research.md` §1).
Read-only research; no `.lua`/`config.lua`/`fxmanifest.lua`/`SPEC.md` file
was touched to produce this document.

**Confidence convention used throughout** (same as this project's established
standard, see `phase5_features_research.md`'s handling of the unconfirmed
`prop_doghouse_01` lead): a claim is only marked CONFIRMED when at least two
independent sources corroborate it; single-source leads are marked
UNCONFIRMED/PLAUSIBLE and flagged as such, never silently upgraded.

---

## Question 1 — dependency maintenance status

### Bottom line: **RESOLVED, high confidence**, with one caveat honestly carried forward

Previous passes only got as far as "the repos respond to a raw manifest
fetch," which Pass #5 explicitly and correctly declined to call evidence of
active maintenance. This pass went further by using `github.com` HTML pages
and `raw.githubusercontent.com` file reads directly (not the GitHub REST
API, and not search-engine summaries alone) — both were reachable this
session where `api.github.com` was not.

### What was independently confirmed

**`api.github.com` is still blocked in this environment — reproduced,
not just carried forward.** `https://api.github.com/repos/overextended/ox_lib`
(and the same call against `oxmysql`, `ox_target`, `ox_inventory`,
`communityox/ox_lib`, `orgs/communityox`) all returned **HTTP 403** this
session. This is the same gate Pass #5 hit. What's new: `github.com`'s own
HTML pages (repo pages, org pages, commit-list pages, releases pages) and
`raw.githubusercontent.com` file reads were **not** blocked, and carry
equivalent information the API would have given — this pass used those
instead, which is why the question could be closed this time.

**The Overextended/CommunityOx history, confirmed from Overextended's own
primary source:**
`raw.githubusercontent.com/overextended/overextended.github.io/main/content/docs/index.mdx`
(Overextended's own current docs site source, read directly) states
verbatim in substance: *"Established in 2021, Overextended began as a
collaborative effort... officially discontinued in 2025... Development
resumed in 2026 with a renewed focus on collaboration with the
community."* This is a primary, first-party source, not a search-engine
inference.

**Independently corroborated by a second, unrelated organization's own
page** — `github.com/communityox` (fetched directly): bio reads
*"Community-driven support for archived Overextended resources"*, and the
page carries GitHub's own archived-org banner: *"This organization was
marked as archived by an administrator on Apr 28, 2026. It is no longer
maintained."* Its pinned `ox_lib`/`ox_inventory`/`oxmysql`/`ox_core` repos
are each individually marked archived too. This corroborates, from a fully
independent org, the same shape of history Overextended's own docs describe:
CommunityOx existed to keep the resources alive during Overextended's 2025
gap, and wound itself down once Overextended's own maintenance resumed.

**Independently corroborated a third way, by raw observable activity (not
a claim by either party):** `github.com/orgs/overextended/repositories`
shows all 37 current Overextended repos, **none carrying an "Archived"
badge** — including `ox_lib`, `ox_target`, `oxmysql`, `ox_inventory`,
`ox_core`. Commit-list pages for each (`github.com/overextended/<repo>/commits/main`,
fetched directly) show real, dated recent activity:

| Repo | Most recent commit seen this session | Notes |
|---|---|---|
| `ox_lib` | **Aug 17, 2026** ("feat(radial): allow open specific radial menu as root", #812) | Very active; several commits Aug 7–17, 2026 |
| `ox_inventory` | **Aug 7, 2026** (3 fix commits same day, incl. a security-relevant one: "reject client-supplied invid for vehicle inventories") | Active |
| `oxmysql` | **Jul 3, 2026** ("chore: update notices and contributing") | Active, slower cadence than ox_lib |
| `ox_target` | **Jun 9, 2026** (README update); last functional commit/version bump **Apr 25, 2026** (v1.18.1) | Still alive, but the quietest of the four — ~2.5 months since a substantive commit as of this report's date (2026-08-24). Consistent with it being a small, feature-stable library rather than a sign of abandonment, but genuinely the slowest-moving of the four. |

This table is built from directly-read `github.com` commit-list pages, not
search-engine summaries.

**Package/version cross-check:** `raw.githubusercontent.com/overextended/oxmysql/main/package.json`
(read directly) confirms `"author": "Overextended"`, version `2.14.1`,
repository pointing at `github.com/overextended/oxmysql` — i.e. the
canonical npm-side package metadata agrees the current home is Overextended,
not CommunityOx. (Note: this pass's own earlier attempt to fetch
`ox_lib`'s `CHANGELOG.md` at `raw.githubusercontent.com/.../main/CHANGELOG.md`
404'd — that file doesn't exist at that path; not a maintenance signal,
just a wrong guessed path, recorded so a future pass doesn't re-try it.)

**Deprecation/migration notice check:** no deprecation or "migrate to X"
notice was found anywhere in Overextended's current docs, org page, or any
of the four dependency repos' pages read this session, beyond the
historical 2025-discontinuation/2026-resumption note above (which is
resolved history, not a live warning). Nothing found that requires this
resource to change anything about how it consumes `ox_lib`/`ox_target`/
`oxmysql`/`ox_inventory` today.

**`qbx_core` (Qbox), briefly, since it's also a declared dependency:**
one corroborating web-search snippet reports `Qbox-project/qbx_core` last
updated **Aug 22, 2026**, actively releasing (manifest version bumps to
v1.21.0 mentioned). This is framework-level and single-sourced this
session (search snippet only, not independently cross-read against
`github.com/Qbox-project/qbx_core` directly) — flagging as PLAUSIBLE, not
independently confirmed to this pass's own two-source bar, and out of this
role's lane regardless (framework-level findings route to
native-api-assistant, not re-derived here).

### One artifact worth naming honestly, not hiding

A `WebFetch` of `github.com/overextended/ox_lib/releases` reported release
`v3.39.0` as "July 13, **2024**", while the commit-list fetch of the exact
same repo, same session, reported explicit **2026** dates surrounding that
same release (commits Aug 7 and Aug 17, 2026). These two fetches disagree
on the year for the same tag. Given (a) the commit-list page's dates were
explicit ("Aug 17, 2026") rather than inferred, (b) this task's own stated
baseline already has `raw.githubusercontent.com/.../ox_lib/main/fxmanifest.lua`
serving `3.39.0` as the *current* version today (2026-08-24), and (c) ox_lib
ships dozens of releases per year (implausible for a 2-year-old tag to
still be `main`'s current version), the 2026 dating is judged correct and
the "2024" figure is treated as a summarization artifact of the fetch tool
(likely a training-data year-default bias), not a real discrepancy in the
underlying page. Flagging this rather than silently picking a year, per
this project's confidence discipline.

### Not resolved / genuinely out of reach this session

- Exact current open-issue/PR counts and a full history of security
  advisories for each of the four repos were not exhaustively audited
  (spot-checked only, e.g. `ox_inventory`'s Aug 7, 2026 "reject
  client-supplied invid" fix, which reads as a real security-shaped fix but
  its CVE/advisory status was not separately looked up). If a security-
  advisory audit specifically is wanted, that's a distinct, narrower task
  from "is this still maintained," and should be scoped separately.
- `qbx_core`'s status is plausible-but-single-sourced, as noted above.

### Actionable finding: version pinning

`qbx_k9unit/fxmanifest.lua`'s `dependencies` block pins **no versions at
all**:
```lua
dependencies {
    'qbx_core',
    'ox_lib',
    'ox_target',
    'oxmysql',
    'ox_inventory',
}
```
Given the last ~18 months of this exact dependency set experiencing a real
discontinuation → community-fork → fork-wind-down → resumption cycle, "no
version pin" means a server operator's actual installed copy is whatever
they happened to grab, whenever they grabbed it — could be a live-2026
Overextended build, or a frozen CommunityOx-era fork nobody's updated since
early 2026. This resource has no way to detect or warn about that mismatch
today. **Handing to coder-architect / release-manager**: worth a resource-
start sanity check (e.g. assert a minimum `ox_lib` version via
`lib.checkDependency` if `ox_lib` exposes one, or at minimum a manifest
comment naming the last-verified-compatible version) rather than a global
version pin, which this project's own existing manifest convention doesn't
otherwise use. This is a small, low-risk addition, not a migration.

---

## Question 2 — the bark-audio asset gap: practical next step

### Recap of the confirmed baseline (not re-derived — see `phase5_features_research.md` §1)

- No `.ogg`/`.wav`/`.awc`/`.rel` file exists anywhere in this resource.
- `'qbx_k9unit_sounds'` is a placeholder soundset name reused across
  `client/main.lua:168` (`K9_SOUND_SET`, used by `playBark` /
  `PlaySoundOnNetworkEntity`) and `client/movement.lua:882`
  (`DOOR_SCRATCH_SOUND_SET`) — confirmed still true this session, re-grepped
  directly.
- The real, full RAGE-audio pipeline (`.awc` containers + `dat151`/`dat54`
  REL metadata compiled as a DLC-shaped audio bank, loaded via
  `REQUEST_SCRIPT_AUDIO_BANK`) is the mechanism `PlaySoundFromEntity` needs
  to resolve a *custom* soundset — already researched and correctly scoped
  as non-trivial in `phase5_features_research.md` §1. Not re-derived here.

### The concrete, lower-cost alternative this pass identifies: extend the resource's own already-wired NUI bridge

This resource **already has a real, working, always-loaded NUI page** —
this is not hypothetical, it was read directly this session:

- `fxmanifest.lua` (`ui_page 'html/index.html'`, `files {...}`) loads
  `html/index.html` for the entire client session, unconditionally,
  regardless of `Config.Features.HealthStaminaHUD`'s value (per that
  manifest's own comment and `html/app.js`'s header comment, both read
  directly).
- `html/app.js` (read in full) implements a real, working
  `RegisterNUICallback`/`SendNUIMessage` round-trip: a `hud:ready` handshake
  on load, and a `window.addEventListener('message', ...)` dispatcher with
  a `switch (msg.action)` ready to add new action types alongside its
  existing `hud:updateVitals` case.
- `client/hud.lua` is the Lua-side counterpart driving that bridge today
  (for the vitals HUD only).

**None of this currently plays audio** — there is no `<audio>` element, no
Web Audio API / Howler.js code, and no audio-specific message action
anywhere in `html/app.js`/`html/index.html` today (confirmed by direct
read). Extending it for bark playback is genuinely new work, not something
silently already done — but it is new work built on top of NUI plumbing
this resource has already proven it can build, wire, and maintain
correctly (the vitals-HUD bridge), rather than a brand-new subsystem.

**Concrete shape of the extension:**
1. Bundle real, licensed `.ogg` files (e.g. `bark_aggressive.ogg`,
   `bark_alert.ogg`, `bark_calm.ogg`) as `files{}` entries alongside
   `html/index.html`/`style.css`/`app.js`.
2. In Lua (either `client/hud.lua` or a new small `client/audio.lua`),
   on a bark trigger, compute distance between the K9 entity and the local
   player's own ped (`GetDistanceBetweenCoords`, a native already in
   routine use elsewhere in this codebase, e.g. the leash pull-back logic
   in `client/movement.lua`), map it to a 0–1 volume via a simple falloff
   curve, and `SendNUIMessage` a new action (e.g. `bark:play`) carrying
   `{ sound = 'bark_aggressive.ogg', volume = 0.6 }`.
3. In `html/app.js`, add one more `case` to the existing `switch` that
   plays the named file via a plain `<audio>` element (simplest) or the Web
   Audio API (`GainNode` for volume) — no external library strictly
   required for basic volume-scaled playback.

This sidesteps `.awc`/`dat151`/`dat54` authoring entirely. The asset bar
drops from "author RAGE audio-bank metadata" to "obtain 3 real, licensed
`.ogg` files" (e.g. via a CC0/CC-BY source like freesound.org, with a
license check per clip) — the same content-sourcing task `SPEC.md` §9 item
7 already names, just without the extra engineering pipeline on top of it.

### Community precedent for this pattern — three independent sources read directly, not search snippets

- **`Xogy/xsound`** (read directly via `github.com`): NUI/HTML5-audio based,
  plays from URL, exposes `PlayUrlPos()` for 3D-positioned sound with a
  `Distance()` attenuation-radius setter and position-update calls. MIT
  license, 159 stars / 104 forks / 107 commits — the most mature of the
  three found. Last-commit *date* was not independently confirmed this
  session (only commit count/star count were visible in the fetch), so its
  current maintenance recency is not verified to this pass's own bar —
  flagging that gap rather than assuming it's current.
- **`QBus-xyz/xyz-3dsound`** (read directly): explicitly "Spatial 3D audio
  for FiveM via NUI and local audio files," Howler.js-based, `.ogg`/`.mp3`/
  `.weba` supported, exports `Play(coords, song, volume, radius, uniqueId)`
  — nearly the exact shape proposed above. Only 4 commits visible — small/
  young project, a real but minor lead, not a mature dependency candidate
  on its own.
- **`charleshacks/chHyperSound`** (read directly): same NUI + Howler.js +
  `.ogg`-only pattern, `chHyperSound:play`/`chHyperSound:playOnEntity`
  events, automatic distance-based attenuation with a configurable max
  range. **Archived Dec 31, 2022, read-only, not viable as a new
  dependency** — but its existence corroborates the *pattern itself*
  (NUI-based positional audio for FiveM) is a multi-year-old, proven
  technique in this ecosystem, not a novel or risky approach for this pass
  to be recommending.

**Confidence: the pattern's validity is corroborated by three independently
read sources (comfortably above the two-source bar).** Whether to build a
small bespoke bridge in-house (this resource's own established pattern,
proven with the HUD) versus take on an actual `dependencies` entry on
`xsound` is a real design choice, not resolved here — leaning toward the
in-house extension given this resource already owns and maintains an
equivalent bridge, and `xsound`'s own current maintenance recency wasn't
independently confirmed this session.

### A cheap, unconfirmed idea worth a 5-minute in-engine test before either path — flagged as a hypothesis, not a finding

`client/movement.lua:859-868` already defines and uses real, valid vanilla
scenario names for the door-scratch animation: `WORLD_DOG_BARKING_SHEPHERD`,
`WORLD_DOG_BARKING_ROTTWEILER`, `WORLD_DOG_BARKING_RETRIEVER` (confirmed
in actual use in this exact codebase, not a new claim). **Untested and
unconfirmed by any source this session:** whether playing one of these via
`TASK_START_SCENARIO_IN_PLACE` produces vanilla, audible bark audio as a
side effect of the scenario's own animation clip (many GTA ambient
scenarios carry embedded audio events fired by the animation system itself,
independent of any custom sound bank) — if so, this could give a genuine
zero-custom-asset generic bark cue for free. This is **a hypothesis, not a
finding** — no source (this session's tooling couldn't reach a definitive
GTA animation/audio-events reference) confirms or rules this out, and even
if true it would likely only cover one generic bark per breed (not
distinct aggressive/alert/calm *types*, since there's one barking scenario
per breed, not one per emotional type). Worth a literal in-engine test
(play the scenario, listen) before committing engineering time to either
option above — cheap to falsify, currently unverified either direction.

### Honest fallback option

Staying a documented gap and shipping mute remains valid and is, in effect,
the current shipped state today (a harmless no-op, not a crash or an
error). This is the right call if nobody is willing to commit to sourcing/
licensing real bark audio — that content-sourcing step is required
regardless of which engineering path (RAGE bank vs. NUI bridge) is chosen,
so it is the actual bottleneck, not the pipeline choice.

### Recommendation

For whoever specs Phase 5's `AdvancedBarkRadial`/door-scratch audio: the
NUI-bridge extension (Option B above) is the recommended default over the
full RAGE audio-bank pipeline, specifically because it reuses this
resource's own already-proven, always-loaded NUI infrastructure and drops
the asset bar from RAGE-audio authoring to "3 licensed `.ogg` files." This
is a genuine change of technical direction from the RAGE-bank framing
`SPEC.md` §7 and `phase5_features_research.md` §1 assumed — flagging to
product-manager (spec decision) and coder-architect/coder-frontend
(implementation, small-scope: extends `html/app.js` + `client/hud.lua` or
a new `client/audio.lua`, does not touch many files) before Phase 5
implementation commits to the heavier pipeline. The vanilla-scenario-audio
hypothesis above is worth a five-minute in-engine check first, since if
true it's strictly cheaper than either full option for at least a generic
bark.

---

## Confidence summary

| Finding | Confidence | Basis |
|---|---|---|
| Overextended is the current canonical home for ox_lib/ox_target/oxmysql/ox_inventory | **High** | 3 independent primary sources: Overextended's own docs history page, CommunityOx's own archived-org banner, and directly-observed commit activity across all 4 repos through Aug 2026 |
| CommunityOx was a temporary 2025-era fork, now itself archived (Apr 28, 2026) | **High** | Read directly from `github.com/communityox`'s own page and archived-org banner |
| No current deprecation/migration notice affecting this resource's usage | **High** (absence checked directly across all 4 repos' pages + Overextended's docs site) | — |
| `ox_target`'s slower commit cadence vs. the other three | **High** (directly observed dates), **not** evidence of abandonment on its own | Commit-list page read directly |
| `api.github.com` still blocked in this environment | **High** (reproduced this session, 6 separate calls) | Direct 403s |
| `qbx_core` actively maintained | **Medium** (single search-engine source, not independently cross-read) | Out of this role's lane regardless |
| NUI-based bark-audio bridge is a viable, proven pattern | **High** (3 independent sources read directly) | `xsound`, `xyz-3dsound`, `chHyperSound` |
| `xsound`'s *current* maintenance recency | **Unconfirmed** | Commit count/stars seen, no commit date confirmed |
| Vanilla `WORLD_DOG_BARKING_*` scenario producing free bark audio | **Unconfirmed — hypothesis only** | No source found either way; flagged as a cheap thing to test in-engine, not asserted |
