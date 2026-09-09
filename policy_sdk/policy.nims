## Build recipe for a Nim wasm policy module (include from a policy's .nims).
## Target: wasm32-wasi reactor, no threads, ARC, goto exceptions — the same
## shape the arena components and the play SDK proved on this engine.

import std/os

let
  sdkDir = currentSourcePath().parentDir()
  wasiSdk = getEnv("WASI_SDK_PATH")

if wasiSdk.len == 0:
  quit("WASI_SDK_PATH must point at wasi-sdk 33 " &
    "(tools/runtime_spike/fetch_deps.sh prints it).", 1)

switch("path", sdkDir)
switch("threads", "off")
switch("os", "linux")
switch("cpu", "wasm32")
switch("cc", "clang")
switch("clang.exe", wasiSdk / "bin" / "clang")
switch("clang.linkerexe", wasiSdk / "bin" / "clang")
switch("clang.cpp.exe", wasiSdk / "bin" / "clang++")
switch("clang.cpp.linkerexe", wasiSdk / "bin" / "clang++")
switch("mm", "arc")
switch("exceptions", "goto")
switch("define", "noSignalHandler")
switch("define", "release")
switch("define", "useMalloc")
switch("define", "paintbotPolicyWasm")
switch("noMain", "on")
switch("passC", "-I" & sdkDir)
switch("passL", "-mexec-model=reactor")
switch("passL", "-Wl,--export=policy_alloc")
switch("passL", "-Wl,--export=policy_init")
switch("passL", "-Wl,--export=policy_on_message")
switch("passL", "-Wl,--export-memory")
switch("passL", "-Wl,--max-memory=67108864")
