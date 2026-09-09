# paintbot-wasm: Paintbot Season 2 as a game-hosted (single-pod) Coworld

Decided 2026-09-09 (daveey): coworld name `paintbot-wasm`; policies are
wasm32-wasi core modules; the baseline is a full port of the three LLM
starter personas; the only published variant is `battle-royale-s2`.

## Shape

The platform's game-hosted player runtime (`game.player_runtime:
"game-hosted"`, metta #21878-#21885) gives the game one verified file per
seat and no player pods. Paintbot Season 2 keeps its wire byte-for-byte:

    policy wasm  <->  /bin/policy-host (one child process per seat)
                 <->  loopback websocket /player?slot=N&token=T
                 <->  the unchanged play-seat transport (ingress/outbound)
                 <->  the shell episode (plays in wasmtime, as today)

The game (`/bin/ctf`) sees `COGAME_PLAYER_SEATS_URI`, reads the seats
document, and spawns `/bin/policy-host` per seat after its HTTP server is
listening. Each child loads the seat's wasm, runs `policy_init`, connects to
the game's own player websocket, and pumps: every server->seat binary message
becomes one `policy_on_message` call; everything the guest `send`s is written
to the socket after the call returns. The child's stdout/stderr IS the seat
log (`log_uri`). `player_status.json` records every child's exit.

## Policy module contract (docs/POLICY_WASM.md)

- wasm32 core module; WASI preview 1 imports allowed (no filesystem, no
  network; stdout/stderr go to the seat log; clocks and random work).
- exports: `memory`, `policy_alloc(len)->ptr`, `policy_init(slot)->i32`,
  `policy_on_message(ptr,len)->i32`; optional `_initialize`.
- imports (`policy` namespace): `send(ptr,len)->i32`,
  `log(level,ptr,len)`, `llm_chat(ptr,len)->i32` (response length or a
  negative error), `llm_read(dst,cap)->i32`.
- limits per seat: 64 MiB memory, fuel per message, 1 s wall epoch backstop
  per guest call (host calls excluded), 24 LLM calls per episode.
- faults: invalid file / init failure -> child exit 3 before joining -> the
  game declares GamePlayerFailure for that slot. A trap or budget fault
  mid-match -> child exits, socket closes, the seat's standing ladder keeps
  riding (same as a dropped pod).

## Files

- `src/policy_host.nim`, `src/policy/wasi_host.nim`, `src/policy/llm_proxy.nim`
- `src/ctf/hosted.nim` + hooks in `src/ctf.nim` / `src/ctf/server.nim`
- `policy_sdk/` (Nim SDK: build recipe, imports, wire, canonical JSON)
- `policies/wasm/starter/` (the three personas), `tools/build_policy_wasm.sh`
- `coworld_manifest_template.json`, `compose.yaml`, `Dockerfile`
- tests: `tests/test_policy_host.nim`, `tests/test_hosted_seats.nim`

## Definition of done

Local: unit tests; `coworld run-episode` with 16 hosted seats -> results,
replay, 16 seat logs; replay renders in the static viewer; a run with an
LLM key shows model calls in seat logs; `coworld certify` passes.
Hosted: canonical upload; league rounds complete; two ranked players;
featured replay on softmax.com/paintbot-wasm; seat logs show sidecar calls.

## Status (2026-09-09)

Done locally: policy-host + hosted seats (16-seat episodes, invalid-file
failure path, player_status.json), the SDK, the echo policy, the three starter
personas as wasm (canned and live-model runs verified through the Anthropic
route), manifest/compose/Dockerfile, unit tests, README, CI job.
Next: `coworld build` (Docker), `coworld run-episode`, `coworld certify`,
upload, secret, league, champions, verification on softmax.com.
Blocked on the user: creating the public GitHub repo Metta-AI/cogame-paintbot
(the permission classifier refused both `gh repo create` and `gh api`).
