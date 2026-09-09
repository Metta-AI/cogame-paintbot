## The game-hosted seats document: parsing, the log-first start contract,
## exit polling, and player_status.json.

import std/[json, os, osproc, strutils, unittest]
import ../src/ctf/hosted
import ../src/ctf/[sim_config, sim_types]

proc workspace(): string =
  result = getTempDir() / ("paintbot-hosted-test-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "logs")

proc seatsDoc(dir: string, seats: int, schema = "coworld-player-seats/1"): string =
  var entries = newJArray()
  for slot in 0 ..< seats:
    writeFile(dir / ("policy" & $slot), "not wasm")
    entries.add(%*{"slot": slot, "file_uri": "file://" & dir / ("policy" & $slot),
      "content_hash": "sha256:" & repeat("0", 64), "size_bytes": 8,
      "log_uri": "file://" & dir / "logs" / ("policy_agent_" & $slot & ".log"),
      "artifact_uri": "file://" & dir / ("policy_artifact_" & $slot & ".zip")})
  result = dir / "player_seats.json"
  writeFile(result, $(%*{"schema": schema, "seats": entries,
    "player_status_uri": "file://" & dir / "player_status.json"}))

suite "hosted seats":
  test "the seats document is parsed into staged seats":
    let dir = workspace()
    putEnv(HostedSeatsEnv, "file://" & seatsDoc(dir, 3))
    loadHostedSeats()
    check hostedRuntime.enabled
    check hostedRuntime.seats.len == 3
    check hostedRuntime.seats[2].slot == 2
    check hostedRuntime.seats[2].logPath.endsWith("policy_agent_2.log")
    check hostedRuntime.statusPath.endsWith("player_status.json")
    hostedRuntime.enabled = false
    delEnv(HostedSeatsEnv)

  test "a wrong schema is refused":
    let dir = workspace()
    putEnv(HostedSeatsEnv, "file://" & seatsDoc(dir, 1, schema = "coworld-player-seats/9"))
    expect CtfError:
      loadHostedSeats()
    delEnv(HostedSeatsEnv)

  test "starting writes every seat log, polling reports exits, finishing writes status":
    let dir = workspace()
    putEnv(HostedSeatsEnv, "file://" & seatsDoc(dir, 2))
    # A stand-in policy-host that exits 3 (invalid policy) at once.
    let fakeHost = dir / "fake-host"
    writeFile(fakeHost, "#!/bin/sh\necho \"fake host $*\"\nexit 3\n")
    setFilePermissions(fakeHost, {fpUserExec, fpUserRead, fpUserWrite})
    putEnv(PolicyHostEnv, fakeHost)
    loadHostedSeats()
    var config = defaultGameConfig()
    config.slots.setLen(2)
    config.slots[1].token = "tok-1"
    startHostedSeats(12345, config)
    for slot in 0 .. 1:
      check fileExists(dir / "logs" / ("policy_agent_" & $slot & ".log"))
    var exits: seq[tuple[slot, code: int]]
    for _ in 0 ..< 200:
      exits.add(pollHostedSeats())
      if exits.len == 2: break
      sleep(20)
    check exits.len == 2
    check exits[0].code == HostedExitInvalidPolicy
    check hostedFailureMessage(exits[0].slot, exits[0].code).contains("not a valid")
    finishHostedSeats()
    let status = parseJson(readFile(dir / "player_status.json"))
    check status["schema_version"].getStr == "1"
    check status["players"].len == 2
    check status["players"][1]["state"].getStr == "exited"
    check status["players"][1]["exit_code"].getInt == 3
    let log1 = readFile(dir / "logs" / "policy_agent_1.log")
    check log1.contains("--token=tok-1")
    check log1.contains("finished")
    delEnv(HostedSeatsEnv)
    delEnv(PolicyHostEnv)
