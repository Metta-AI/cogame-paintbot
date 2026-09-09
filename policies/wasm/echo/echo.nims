import std/os

let policyDir = currentSourcePath().parentDir()

include "../../../policy_sdk/policy.nims"

switch("nimcache", policyDir.parentDir() / ".build" / "echo-nimcache")
switch("out", policyDir.parentDir() / ".build" / "echo.wasm")
