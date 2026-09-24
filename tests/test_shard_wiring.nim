## The tripwire for the dark-test failure mode: a test FILE on disk that no
## shard imports contributes zero cases, silently — CI compiles green and
## the suite total just quietly excludes it. It has happened twice for real:
## the v59 shard-compile incident shrank the suite the same silent way, and
## test_glory (the entire GloryVersion 10 pricing-law suite, 31 tests) ran
## dark from increment 1 THROUGH glory going live in gameplay. Two lanes
## reporting different suite totals (882 vs 859) is this mode's smell.
##
## This test asserts, from the checked-out sources themselves, that every
## tests/test_*.nim is imported by a shard (or tests.nim), or is run by its
## dedicated CI step. Adding an unwired test file fails the suite.

import std/[os, strutils, unittest, sets]

suite "shard wiring":
  test "every test file on disk runs in CI":
    let testsDir = currentSourcePath().parentDir()
    var imported = initHashSet[string]()
    for carrier in ["shard_1.nim", "shard_2.nim", "shard_3.nim",
                    "shard_4.nim", "tests.nim"]:
      let path = testsDir / carrier
      if not fileExists(path):
        continue
      for rawLine in readFile(path).splitLines:
        let line = rawLine.strip().strip(chars = {','})
        if line.startsWith("test_"):
          imported.incl(line)
    let workflow = readFile(testsDir / ".." / ".github" / "workflows" / "build.yml")
    for standalone in ["test_starter_policy", "test_hosted_seats"]:
      check workflow.contains(standalone & ".nim")
      imported.incl(standalone)
    check imported.len > 0
    var dark: seq[string] = @[]
    for kind, path in walkDir(testsDir):
      if kind != pcFile:
        continue
      let name = path.extractFilename()
      if not (name.startsWith("test_") and name.endsWith(".nim")):
        continue
      let module = name[0 ..< name.len - 4]
      if module notin imported and module != "test_shard_wiring":
        dark.add(module)
    checkpoint("dark (unwired) test files: " & $dark)
    check dark.len == 0
