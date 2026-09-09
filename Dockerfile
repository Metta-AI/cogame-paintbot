# Build Docker. ONE image, THREE entrypoints: /bin/policy-host (the
# game-hosted wasm seat runtime the game spawns per seat), /bin/ctf (the game server, which
# also runs the paintball KOTH mode when the game config gates it on) and
# /bin/paintball-player (the thin paintball seat registrar). The paintball
# policy set is env-switched inside this same image (PLAYER_PROMPT vs
# PLAYER_SCRIPTED), which is what keeps a champion and a scripted filler
# byte-identical apart from their environment.
# /bin/paintball-player is deprecated since 0.7.253 and is retained only for
# paintball configs explicitly enabled with allowDeprecatedModes: true.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    xz-utils && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/ctf
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on"
ARG CtfRuntimeFlags="-d:noSignalHandler -d:shellStaticWasmtime"
ARG NimCommand="c"
ARG NimMain="src/ctf.nim"
# Engine build stamp (tools/sim_sources_stamp.sh over the sim sources), baked
# into the server so every recording it writes carries "engineStamp" in its
# header and the replay viewer can tell a same-build replay from a foreign one
# (src/ctf/build_stamp.nim). The build context has no .git to derive it from,
# so the caller passes it: compose.yaml forwards $SIM_SOURCES_STAMP and the
# upload workflow exports it. Empty means "unstamped" — the pre-stamp header.
ARG SIM_SOURCES_STAMP=""
RUN tools/runtime_spike/fetch_deps.sh > /tmp/runtime_deps.env && \
  wasmtime_root="$(sed -n 's/^WASMTIME_C_API=//p' /tmp/runtime_deps.env)" && \
  test -f "$wasmtime_root/include/wasmtime.h" && \
  test -f "$wasmtime_root/lib/libwasmtime.a" && \
  WASMTIME_C_API="$wasmtime_root" nim $NimCommand \
    $NimFlags \
    $CtfRuntimeFlags \
    -d:ctfSimSourcesStamp="${SIM_SOURCES_STAMP}" \
    --nimcache:/tmp/ctf-nimcache \
    --out:ctf \
    $NimMain && \
  nim c \
    $NimFlags \
    --nimcache:/tmp/paintball-player-nimcache \
    --out:paintball-player \
    src/paintball_player.nim && \
  WASMTIME_C_API="$wasmtime_root" nim c \
    $NimFlags \
    $CtfRuntimeFlags \
    --nimcache:/tmp/policy-host-nimcache \
    --out:policy-host \
    src/policy_host.nim

FROM build AS runtime-proof

RUN wasmtime_root="$(sed -n 's/^WASMTIME_C_API=//p' /tmp/runtime_deps.env)" && \
  wasi_root="$(sed -n 's/^WASI_SDK_PATH=//p' /tmp/runtime_deps.env)" && \
  test -f "$wasmtime_root/include/wasmtime.h" && \
  test -x "$wasi_root/bin/clang" && \
  WASI_SDK_PATH="$wasi_root" nim c -f --hints:off \
    play_sdk/examples/hello_play.nim && \
  WASI_SDK_PATH="$wasi_root" nim c -f --hints:off \
    play_sdk/reference/edge_ride.nim && \
  WASMTIME_C_API="$wasmtime_root" nim c --threads:on -d:release \
    -d:noSignalHandler -d:shellStaticWasmtime \
    --hints:off --path:src --nimcache:/tmp/shell-probe-nimcache \
    --out:shell-probe \
    tools/shell_probe.nim

CMD ["./shell-probe"]

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/ctf
COPY --from=build /workspace/ctf/ctf /bin/ctf
COPY --from=build /workspace/ctf/paintball-player /bin/paintball-player
# The game-hosted seat runtime: one process per wasm policy file
# (src/policy_host.nim, docs/POLICY_WASM.md).
COPY --from=build /workspace/ctf/policy-host /bin/policy-host
COPY --from=build /workspace/ctf/*.json ./
COPY --from=build /workspace/ctf/data ./data

CMD ["/bin/ctf"]
