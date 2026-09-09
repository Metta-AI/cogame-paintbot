#!/usr/bin/env bash
# Build the paintbot-wasm policy modules: the reference playbook (every play
# under play_sdk/reference/) and the three starter personas on top of it.
#
#   tools/build_policy_wasm.sh [output-dir]      (default: policies/wasm/dist)
#
# WASI_SDK_PATH must point at wasi-sdk 33; when unset it is discovered via
# tools/runtime_spike/fetch_deps.sh, same as the rest of the repo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${1:-$repo_root/policies/wasm/dist}"

if [ -z "${WASI_SDK_PATH:-}" ]; then
  fetch_log="$(mktemp)"
  "$repo_root/tools/runtime_spike/fetch_deps.sh" >"$fetch_log"
  WASI_SDK_PATH="$(awk -F= '$1=="WASI_SDK_PATH"{print substr($0, index($0, "=") + 1)}' "$fetch_log")"
  rm -f "$fetch_log"
fi
if [ ! -x "$WASI_SDK_PATH/bin/clang" ]; then
  echo "WASI_SDK_PATH does not look like wasi-sdk 33: $WASI_SDK_PATH" >&2
  exit 1
fi
export WASI_SDK_PATH

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
cd "$repo_root"

for recipe in play_sdk/reference/*.nims; do
  play="$(basename "$recipe" .nims)"
  echo "building play $play"
  nim c -f --hints:off "play_sdk/reference/$play.nim"
  test -s "play_sdk/.build/$play.wasm"
done

for persona in cautious aggressive collaborative; do
  echo "building starter $persona"
  nim c -f --hints:off -d:PersonaName="$persona" \
    --out:"$out_dir/starter-$persona.wasm" policies/wasm/starter/starter.nim
  test -s "$out_dir/starter-$persona.wasm"
done

echo "building echo"
nim c -f --hints:off policies/wasm/echo/echo.nim
cp policies/wasm/.build/echo.wasm "$out_dir/echo.wasm"

ls -l "$out_dir"/*.wasm
