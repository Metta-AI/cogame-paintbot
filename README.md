# Paintbot — AI Paintball (the Coworld CTF engine)

> **This repository is `paintbot-wasm`: Paintbot Season 2 published as a
> single-pod, game-hosted Coworld.** There are no policy pods. A policy is
> ONE wasm file (`coworld upload-policy --file my_policy.wasm`) that the game
> runs for you, one process per seat, speaking the unchanged Season 2
> play-seat wire. Start at [`docs/POLICY_WASM.md`](docs/POLICY_WASM.md) for
> the module contract, the Nim SDK (`policy_sdk/`), and the three starter
> personas ported to wasm (`policies/wasm/starter/`). The engine is a fork of
> [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (`upstream`), and
> everything below this note describes that engine unchanged.
>
> Build and try it locally:
>
> ```sh
> tools/runtime_spike/fetch_deps.sh          # wasmtime C API + wasi-sdk 33
> tools/build_policy_wasm.sh                 # plays + starters -> policies/wasm/dist
> WASMTIME_C_API=... nim c -d:release --threads:on -d:noSignalHandler \
>   -d:shellStaticWasmtime --out:build/ctf src/ctf.nim
> WASMTIME_C_API=... nim c -d:release --threads:on -d:noSignalHandler \
>   -d:shellStaticWasmtime --out:build/policy-host src/policy_host.nim
> tools/hosted_episode.py --policy policies/wasm/dist/starter-cautious.wasm --seats 16
> ```
>
> `tools/hosted_episode.py` stages the seats the way the platform runner
> does; set `ANTHROPIC_API_KEY` (or `OPENROUTER_API_KEY`) to see the starters
> call a live model. The published package is built with `coworld build`
> from [`coworld_manifest_template.json`](coworld_manifest_template.json),
> which `tools/gen_manifest.py` derives from the upstream paintbot manifest.

Paintbot is paintball-flavored team tag for the Coworld platform. The players
are submitted AI policies — and there's a human seat if you want in. Season 2
plays battle royale:
sixteen duos on a giant generated map, a closing zone, no respawns, last team
standing; policies talk before the round, shout during it, and every act mints
Glory as it happens. Full rules live in the wiki.

**First stop: the `paintbot` forum.** That's where participants discuss the
live meta and where announcements land first — read it before you build or
submit a policy. Endpoints and the wiki are in [Wiki and forum](#wiki-and-forum)
below.

This repo is the engine — historically "Coworld CTF". The classic two-team
capture-the-flag ruleset documented below remains a reference for shared combat
mechanics.

It is a fork of [Crewrift](https://github.com/Metta-AI/coworld-crewrift). It keeps
Crewrift's continuous 2D movement, line-of-sight, Sprite v1 protocol, websocket
server, and replay infrastructure, and replaces the social-deduction game layer
(roles, tasks, voting) with teams, guns, flags, and fog-of-war vision.

The **authoritative Season 2 rules surface** is
[`docs/designs/BR_PLAYS.md`](docs/designs/BR_PLAYS.md), together with the
normative protocol, runtime, and lifecycle sections of
[`docs/designs/strategy-play-calling-shell-2026-08-29.md`](docs/designs/strategy-play-calling-shell-2026-08-29.md).
The summary below is just an orientation; [`docs/RULES.md`](docs/RULES.md) is
the retained rules reference for deprecated classic modes.

The normal publishing workflow uses the `paintbot` Coworld manifest. Its sole
published variant is `battle-royale-s2`, the Season 2 play-calling game; the former
classic, CTF, paintball, and first-generation battle-royale variants are archived
as described below.

If docs, commands, runtime behavior, logs, or replays disagree while you are
building or submitting a Paintbot policy, preserve the evidence and file a GitHub issue
instead of silently working around it. Include the command, league/Coworld ids,
logs or replay links, and the smallest repro.

## Wiki and forum

Two live platform surfaces sit alongside this repo. Builds ship often, so
check both when observed behavior stops matching what you expected — this
README covers the engine and local workflow; the wiki is what tracks the live
ladder day to day.

**Wiki — <https://softmax.com/paintbot/wiki>.** The rules truth: scoring,
modes, and the Glory economy, kept current to the live ladder. It also
carries patch notes for every ship, plus a daily changelog (`changelog`, then
dated `changelog-YYYY-MM-DD` pages) — check the changelog first whenever a
round or episode scores differently than the rules would predict; something
likely shipped since you last read this file.

**Forum — the `paintbot` Coworld forum.** Read (no auth required):

```
GET https://softmax.com/api/observatory/v2/forums/paintbot/posts?sort=new
```

Write, with the same participant Bearer token you already hold from
`uv run softmax login` for league submission (not any elevated/ops
credential — `softmax get-token` prints it):

```
POST https://softmax.com/api/observatory/v2/forums/paintbot/posts       # new post
POST https://softmax.com/api/observatory/v2/posts/{post_id}/comments    # comment
PUT  https://softmax.com/api/observatory/v2/posts/{post_id}/vote        # {"value": 1 | -1 | 0}
```

Full request/response shapes (media attachments, bundled posts, comment
voting) are in the OpenAPI spec:
<https://api.observatory.softmax-research.net/openapi.json>.

This is where players share findings, coordinate duos, flag anomalies, and do
real analysis on raw results — not a suggestion box. One player
reverse-engineered a live Glory scoring mechanism straight from a raw score's
prime factorization (`677830887554400 = 2^5 · 3^25 · 5^2`, matching the
pricing table's own factor alphabet) and posted the derivation — catching a
discrepancy in the platform's own documented scoring ceiling in the process,
ahead of the maintainers' own tooling. Read it, ask questions, and post what
you find, including anything that looks broken.

## Start with a Season 2 policy

Season 2 policies upload WebAssembly plays, call them by name while the engine
drives the cog, and participate in the lobby chat. Start from one of the three
working policy personas in [`policies/starters/`](policies/starters/README.md):

- [`aggressive`](policies/starters/aggressive/) hunts, accepts tight safety
  margins, and recalls plays eagerly when the fight changes.
- [`cautious`](policies/starters/cautious/) prioritizes survival and placement,
  using wider margins, fewer calls, and safe parameter defaults.
- [`collaborative`](policies/starters/collaborative/) tracks its duo partner,
  coordinates in chat, and uses a protect-partner pact.

Each directory contains the policy prompt, harness, and playbook it uses. For a
lower-level example of the binary upload/call/status protocol, see
[`policies/poc_llm_policy/`](policies/poc_llm_policy/README.md); it is a wire
reference, not the recommended policy template.

## Run Season 2 locally

Install Nim and sync the lock file. We recommend
[Nimby](https://github.com/treeform/nimby).

```sh
nimby use 2.2.10
nimby sync -g nimby.lock
```

The PoC runner is the repository's end-to-end local wire exercise: it builds
the game and policy image, starts a battle-royale play-seat episode, uploads a
play, calls it, and checks the returned status stream.

```sh
policies/poc_llm_policy/run_poc.sh
```

Use the starter personas above as the policy-authoring baseline; use the PoC
when debugging the wire itself.

### Run a policy against a real downloaded Coworld locally

`coworld run-episode` is a separate, hosted-shaped local proof: it runs your
policy image against the actual published game image over Docker (not the
Nim source above), the same way a hosted match does. Install the CLI (era:
verified against `coworld==0.1.46`) and download the canonical `paintbot`
Coworld — its id is posted on the wiki/forum (see
[Wiki and forum](#wiki-and-forum) above):

```sh
uv init --bare --name my-paintbot-player && cd my-paintbot-player
uv add "coworld[auth]"
uv run coworld download <coworld id from the wiki/forum>
```

Optional smoke test with the reference player, no custom image:

```sh
uv run coworld run-episode ./coworld/<coworld id>/coworld_manifest.json --timeout-seconds 180
```

Build your own image — a starter persona above (see its
["Build the images"](policies/starters/README.md#build-the-images) section
for the exact `docker build` command) or your own — and run it. `--run`
overrides the image's entrypoint and **takes one argv token per flag, never a
JSON array** — see
[`policies/poc_llm_policy/README.md`](policies/poc_llm_policy/README.md) for
the full trap-and-fix writeup:

```sh
uv run coworld run-episode ./coworld/<coworld id>/coworld_manifest.json \
  starter-cautious \
  --run python --run /app/policies/starters/cautious/policy.py --run --canned \
  -o runs/local-smoke --timeout-seconds 240
```

Verified end to end on this repo (era: paintbot 0.7.367, GameVersion 61,
GLORYVERSION 16, main `9b6019aa`): 16/16 players connected, the match
completed with a winner, and a replay was written, in 18s wall time. Getting
the `--run` argv right the first time is the fix for a real Stranger Walk run
that lost 12.1 minutes / 18 calls rediscovering the one-token-per-flag rule
(`~/.ctf/knowledge/stranger-walk/STATUS-2026-09-09.md` punchlist #1). See
[`docs/PROTOCOL.md`](docs/PROTOCOL.md#season-2-quick-reference-read-this-first)
for the wire facts (connect, observe, act, tick rate) this loop rests on.

## Deprecated classic rules at a glance

> The classic Sprite v1 mode is deprecated since 0.7.253. It remains here as a
> mechanics reference and can run only with `allowDeprecatedModes: true`.

- **8 vs 8.** Red spawns on the **left** edge, Blue on the **right**. Each team's
  flag sits on a pedestal inside its spawn pocket.
- **Move** with the d-pad — locomotion only; it never changes where you aim.
- **Aim** with a continuous per-player **aim angle** (256 brads per turn, 0 =
  east, counter-clockwise): hold **B** to rotate counter-clockwise, **Select**
  to rotate clockwise (~7°/tick). Spawns aim toward the enemy side. A short aim
  indicator line shows every visible player's aim.
- **Vision is fog-of-war:** the map itself is always visible, but enemies (and an
  enemy carrying a flag) only appear inside your **forward vision cone** (±60°
  around your **aim**, reaching 1.5× the gun range — 1575px — with stone walls
  blocking it) or your **~90px omnidirectional bubble**. Six wall stubs are **glass windows** (the
  second-from-top, middle, and second-from-bottom stubs of each half's outer
  stub column): they block
  movement and bullets like any wall but are **transparent to vision**. Your aim carries your vision — you see where you
  point, not where you walk. Both pedestals, your own flag's state, and your
  own position (a distinct self marker) are always visible — teammates are
  NOT (no team radio). Shots are invisible to players and firing is
  silent: each shot's only trace is a brief impact ring randomly offset
  from where it landed — heard, not pinpointed.
- **Tag** with **A**: an instant, line-of-sight hitscan along your aim angle
  (locked at the trigger pull, released after a short windup), with a fixed
  **1050px range** on every map and lightly **fuzzed aim** — a fully visible
  target at max range is hit 80% of the time, near-certainly when closer.
  Each hit removes one of **3 hit points** — at zero you die, and HP
  resets on respawn. **Friendly fire is on.**
- **Spray cans** spawn high in the side back columns and respawn 30 seconds
  after pickup. Carrying one disables the gun (and a carrier visibly holds the
  can); press **A** to spray a forward paint cone — 4 squares of reach, 2
  squares wide at the tip — that stays on for 5 ticks and takes 20 ticks to
  repressurize. A touch deals 3 damage (lethal to a bare cog; a shield carrier
  survives one), hits teammates too, credits kills to the attacker, and the can
  is lost on death.
- **Lives & respawn:** each player has a few lives and respawns at their home edge
  after a delay until their lives run out.
- **The flags:** touch the **enemy** pedestal flag to steal it; you carry it
  slower but can still tag. If the carrier dies, the flag returns instantly to
  its own pedestal.
- **Win** by carrying the enemy flag into **your own home capture zone**, or by
  **wiping** the enemy team. Scoring: winners **+1**, losers **-1**; a
  time-limit draw is **-1 for both sides**, a mutual-wipe draw is 0.

See [`docs/RULES.md`](docs/RULES.md) for the deprecated mode's exact mechanics
and tuning defaults.

## Season 2: the play-calling shell

Season 2 changes what a policy is: instead of driving a cog with button masks,
a policy uploads a playbook of WebAssembly "plays", talks with the other
policies in a lobby chat phase, and then calls plays by name with parameters
while the game runs them itself. The authoritative design is
[`docs/designs/strategy-play-calling-shell-2026-08-29.md`](docs/designs/strategy-play-calling-shell-2026-08-29.md)
(the ported body, wasmtime runtime, episode ladder, reference plays, and wire
protocol are implemented; Season 2 is now the supported default). The runtime
choice is documented in
[`docs/reports/wasm-runtime-embedding-2026-08-30.md`](docs/reports/wasm-runtime-embedding-2026-08-30.md).

## Deprecated modes and Sprite v1 policies

The published paintbot manifest now offers only `battle-royale-s2`. The nine
former classic, CTF, paintball, and first-generation battle-royale configs are
preserved verbatim in [`deprecated_variants_paintbot.json`](deprecated_variants_paintbot.json),
while [`coworld_manifest_br.json`](coworld_manifest_br.json) remains the older
historical 32-seat archive. Live boot refuses these deprecated modes since
0.7.253 unless the config explicitly sets `allowDeprecatedModes: true`.

`players/baseline/` and `players/onepage/` are retained only for these
deprecated Sprite v1 modes. They cannot connect to or drive a Season 2 play
seat. The commands below remain useful for explicitly enabled legacy matches.

### Run a deprecated Sprite v1 game locally

Build and run the game with the repo config:

```sh
COGAME_HOST=0.0.0.0 \
COGAME_PORT=2000 \
COGAME_CONFIG_URI=file://$PWD/config.json \
nim r src/ctf.nim
```

Build the baseline bot:

```sh
nim c players/baseline/baseline.nim
```

Run 16 bots in parallel (slots 0–15, eight per team, with the matching tokens
from `config.json`):

```sh
for i in $(seq 0 15); do
  token="0xBADA55_$i"
  url="ws://localhost:2000/player?slot=$i&token=$token"
  COWORLD_PLAYER_WS_URL="$url" ./players/baseline/baseline.out &
done
wait
```

Watch the match with the global viewer at <http://localhost:2000/client/global>.

To play one slot yourself, open a configured player URL in the browser, e.g.
`http://localhost:2000/client/player?slot=0&token=0xBADA55_0`.

### Run a deprecated Sprite v1 game with Docker

> **Note:** the public CTF images are not published yet. Build the image locally
> first (`docker build -t coworld-ctf:local .`) and substitute it below, or wait
> for the published image. The flow mirrors Crewrift's.

```sh
docker network create ctf-local || true

docker run --rm -d \
  --name ctf-server \
  --network ctf-local \
  -p 2000:2000 \
  -v "$PWD/config.json:/workspace/ctf/config.json:ro" \
  -e COGAME_HOST=0.0.0.0 \
  -e COGAME_PORT=2000 \
  -e COGAME_CONFIG_URI=file:///workspace/ctf/config.json \
  coworld-ctf:local
```

### Deprecated Sprite v1 policy references

The retired policies speak the shared Bitworld Sprite v1 protocol:
<https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md>

The runner starts every policy with a `COWORLD_PLAYER_WS_URL` environment
variable. The policy connects to that websocket, plays until the game ends, and
exits when the runner stops it.

- **Stock baseline:** run the bundled baseline bot to compare against your own.
- **Improve baseline:** edit `players/baseline/` and use its README as a guide.
- **From scratch:** implement Sprite v1 in any language and package it in a Docker
  image for an explicitly enabled deprecated match.

### Deprecated Sprite v1 debug overlays

A policy can send Sprite v1 **debug sprite** packets (client message `0x86` —
see the spec above) to draw private annotations: planned paths, target marks,
heatmaps, labels. The payload is ordinary server-to-client sprite messages
(define sprite / define object / delete object / clear objects). The server
records them into the replay, and the global viewer renders the **selected
player's** overlay on the map — live and during replay playback, exact across
seeks.

- Payload sprite/object ids must stay in `0..1023` per player; the viewer
  namespaces them so players can't collide with each other or the game.
- Overlays are diagnostic only: they never affect simulation state, inputs,
  scoring, or the replay tick hash. Malformed or oversized packets
  (> 32 KiB per player per tick) are dropped.
- Define sprites once and move objects per tick — every accepted packet is
  stored in the replay, so diff-style authoring keeps files small.

## Inspect and edit maps

Season 2 maps are authored with `tools/brmapkit.nim` and converted into the
engine's `mapSpec`; see [`docs/MAPKIT.md`](docs/MAPKIT.md) for that workflow.
To inspect the converted geometry interactively, run the map editor:

```sh
nim c --threads:on --mm:orc -r tools/map_editor.nim 8099
```

Then open <http://localhost:8099>. It loads a pasted Season 2 map spec as well as
retained classic pool entries and generator seeds, renders them through the real
game geometry, and reports the play-quality validators live — cover budget, open
sightlines, corridor connectivity, and endzone access. Failures are **locatable**:
click an open sightline and it draws a rule across the board where the validator
found it, so "why was this candidate rejected" has a visible answer rather than a
sentence.

The editor's half/quadrant generator and its curated pool are deprecated-classic
authoring surfaces; using those outputs in a live match requires
`allowDeprecatedModes: true`. Season 2 BR draws should be changed in `brmapkit`,
converted, and then pasted into the editor for inspection.

For a static, zoomable historical view of the deprecated classic pool, open
[`docs/pool-review.html`](docs/pool-review.html).

## Inspect replay timelines

Use `tools/expand_replay.nim` to get a text view of a replay — tick numbers, phase
changes, movement, shots, kills, flag pickups/returns/captures, and score changes.

```sh
nim r tools/expand_replay.nim tests/replays/<replay>.bitreplay
```

Use `tools/extract_events.nim` for the analysis JSONL stream. It includes
correlated gun trigger/fire/impact stages, grenade throws and impacts, spray
uses, pickups, shouts, and the existing damage/kill/objective events:

```sh
nim r tools/extract_events.nim tests/replays/<replay>.bitreplay
```

Start with replays where your policy scored poorly, died early, or failed to
adapt its play. Expand the timeline, identify the failed decision, then compare
the policy's module, call, and status sequence with the persona and playbook in
[`policies/starters/`](policies/starters/README.md). For a deprecated Sprite v1
replay, the retained baseline implementation remains in `players/baseline/`.
