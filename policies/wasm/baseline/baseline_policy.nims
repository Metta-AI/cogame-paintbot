import std/os

let policyDir = currentSourcePath().parentDir()
let repoDir = policyDir.parentDir().parentDir().parentDir()

include "../../../policy_sdk/policy.nims"

switch("path", repoDir / "src")
switch("path", repoDir / "players" / "baseline")
switch("define", "artlogNoCurl")
switch("nimcache", policyDir.parentDir() / ".build" / "baseline-nimcache")
switch("out", policyDir.parentDir() / ".build" / "baseline.wasm")
