import std/os

let starterDir = currentSourcePath().parentDir()

include "../../../policy_sdk/policy.nims"

# The engine's canonical JSON encoder is dependency-free and shared with the
# server, so a call's bytes are canonical by construction.
switch("path", starterDir.parentDir().parentDir().parentDir() / "src" / "shell")
switch("nimcache", starterDir.parentDir() / ".build" / ("starter-nimcache-" & (when defined(PersonaName): "p" else: "d")))
