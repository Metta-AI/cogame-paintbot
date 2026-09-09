# paintbot-wasm policies: one wasm file per seat

`paintbot-wasm` is Paintbot Season 2 published as a **game-hosted** Coworld:
there are no policy pods. A policy is a single WebAssembly file, uploaded with
`coworld upload-policy --file my_policy.wasm`, and the game runs it inside its
own container, one process per seat (`/bin/policy-host`). Everything the
policy says and hears is the unchanged Season 2 play-seat wire
(`docs/designs/strategy-play-calling-shell-2026-08-29.md` §4.3): the policy
uploads plays (`0xA0`), calls ladders (`0xA1`), acknowledges statuses
(`0xA2`), chats in the lobby (`0xA3`), shouts in the match (`0x81`), and
receives the context (`0xB0`), views (`0xB1`), and chat broadcasts (`0xB2`).
The reference playbook (`play_sdk/reference/*.wasm`) is what a policy uploads;
its plays run in the engine's own runtime exactly as before.

## The module

A wasm32 **core module** (not a component). It may import WASI preview 1
(`wasi_snapshot_preview1`): stdout and stderr go to the seat's private log,
clocks and random work, there is no filesystem and no network.

Exports the host requires:

| export | signature | meaning |
|---|---|---|
| `memory` | | linear memory |
| `policy_alloc` | `(len: i32) -> ptr: i32` | a buffer the host writes one message into; may be reused after the next call |
| `policy_init` | `(slot: i32) -> i32` | called once before the seat joins; nonzero = invalid policy |
| `policy_on_message` | `(ptr: i32, len: i32) -> i32` | one server→seat websocket message; nonzero = fault |
| `_initialize` | `()` | optional (wasi reactor constructors); called once first |

Imports the host provides, module name `policy`:

| import | signature | meaning |
|---|---|---|
| `send` | `(ptr, len) -> i32` | queue one seat→server packet; written after the current call returns. 0 = queued, −1 bad range, −2 more than 64 sends in one call |
| `log` | `(level, ptr, len)` | one line in the seat log (≤ 4096 bytes) |
| `llm_chat` | `(ptr, len) -> i32` | one OpenAI-compatible chat-completions request body; returns the response length, or −1 no route, −2 budget spent, −3 HTTP error (body holds the server's reply), −4 empty request |
| `llm_read` | `(dst, cap) -> i32` | copies the last `llm_chat` response into the guest; returns bytes copied |

Message delivery is one `policy_on_message` per websocket binary message.
While the guest is busy (a model call), the host keeps draining the socket
and delivers only the newest `0xB1` view when it returns; unacknowledged
statuses are redelivered by the server, so nothing is lost. Ping/pong is the
host's job.

## Budgets and faults

| limit | value |
|---|---|
| linear memory | 64 MiB |
| fuel per `policy_on_message` | 2 × 10⁹ instructions (`policy_init`: 2 × 10¹⁰) |
| wall clock per guest call | 1 s, re-armed after each host call returns |
| LLM calls per episode | 24 (`POLICY_LLM_MAX_CALLS`), 45 s each |
| policy file | 100 MiB packed (platform cap) |

`policy-host` exit codes, which the game reads:

- `3` **invalid policy**: it failed to validate, compile, instantiate, or
  `policy_init` failed — before the seat ever joins. The game declares that
  seat's `GamePlayerFailure`, so the episode is charged to that policy and
  retried without it.
- `4` **faulted mid-session**: a trap, out-of-fuel, wall-clock overrun, or a
  nonzero return from `policy_on_message`. The socket closes, the server
  treats it like a dropped pod: the seat's standing ladder keeps riding.
- `0` the socket closed after the match; `5` never connected (a game fault).

## LLM access

The host routes `llm_chat` the way a hosted pod is routed: to the platform
sidecar (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME`, `/v1/chat/completions`, with
`X-Coworld-Player-Slot` so spend and rate limits are attributed to the seat)
or, locally, to OpenRouter with `OPENROUTER_API_KEY`. With neither the call
returns −1 and a policy plays its scripted fallback — which is how offline
certification runs.

## Writing one in Nim

`policy_sdk/` is a Nim SDK: `policy.nim` (imports, `definePolicy`),
`wire.nim` (packet codecs), `seat.nim` (upload/call/ack bookkeeping).
Build with wasi-sdk 33 (`tools/runtime_spike/fetch_deps.sh` prints
`WASI_SDK_PATH`):

```sh
WASI_SDK_PATH=... nim c policies/wasm/echo/echo.nim  # -> policies/wasm/.build/echo.wasm
```

Test it against a local game before uploading — `policy-host` is also a
platform-hosted player when `COWORLD_PLAYER_WS_URL` is set:

```sh
tools/hosted_episode.py --policy policies/wasm/.build/echo.wasm --seats 16
```

Any language that targets wasm32-wasi (Rust, C, Zig, Go/TinyGo, AssemblyScript)
can produce a module with the same exports and imports.

## Seat logs, status, artifacts

Each seat's log is `policy_agent_<slot>.log` on the platform (the host's own
lines are prefixed `[policy-host]`, guest `log` lines `[policy N]`, WASI
stdout/stderr verbatim). The game writes `player_status.json` with every
seat's process outcome. Per-seat artifact zips are not produced in v1.
