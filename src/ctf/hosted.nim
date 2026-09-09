## Game-hosted seats: the single-pod player runtime (docs/POLICY_WASM.md).
##
## When the platform sets COGAME_PLAYER_SEATS_URI, every seat is a verified
## file staged by the runner instead of a policy pod. This module reads that
## seats document, spawns one `policy-host` child per seat once the game's
## own HTTP server is listening (the child loads the wasm and joins the
## /player websocket over loopback, so the Season 2 wire is untouched),
## watches the children, and writes `player_status.json` at the end.
##
## Each child's stdout+stderr IS that seat's log (`log_uri`), which keeps
## private policy output out of the public game log. A child that exits
## with `HostedExitInvalidPolicy` before the match starts is reported to the
## server loop, which declares that seat's GamePlayerFailure.

import std/[json, os, osproc, strutils, times]
import bitworld/runtime
import sim_types

const
  HostedSeatsEnv* = "COGAME_PLAYER_SEATS_URI"
  HostedSeatsSchema* = "coworld-player-seats/1"
  PolicyHostEnv* = "PAINTBOT_POLICY_HOST"
  HostedExitInvalidPolicy* = 3
  HostedExitFaulted* = 4
  HostedExitConnect* = 5
  HostedTerminateGraceMs = 1500

type
  HostedSeat* = object
    slot*: int
    filePath*: string
    logPath*: string
    artifactPath*: string
    contentHash*: string
    sizeBytes*: int
    process: Process
    started*: bool
    exited*: bool
    reported*: bool
    exitCode*: int
    finishedAt*: string

  HostedSeats* = object
    enabled*: bool
    seats*: seq[HostedSeat]
    statusPath*: string
    hostBinary*: string

var hostedRuntime*: HostedSeats

proc hostedSeatsEnabled*(): bool =
  getEnv(HostedSeatsEnv).len > 0

proc resolvePolicyHost(): string =
  result = getEnv(PolicyHostEnv)
  if result.len > 0:
    return
  let beside = getAppDir() / "policy-host"
  if fileExists(beside):
    return beside
  result = "/bin/policy-host"

proc loadHostedSeats*() =
  ## Reads the seats document. Raises on a malformed document: without it
  ## the game cannot seat anyone, so it must not start a lobby it can never
  ## fill.
  let text = readCogameEnv(HostedSeatsEnv)
  let doc = parseJson(text)
  if doc{"schema"}.getStr("") != HostedSeatsSchema:
    raise newException(CtfError,
      "player seats document schema is not " & HostedSeatsSchema)
  hostedRuntime.enabled = true
  hostedRuntime.hostBinary = resolvePolicyHost()
  hostedRuntime.statusPath = pathFromCogameUri(
    doc{"player_status_uri"}.getStr(""), "player_status_uri")
  hostedRuntime.seats = @[]
  for entry in doc{"seats"}:
    var seat = HostedSeat(slot: entry{"slot"}.getInt(-1))
    if seat.slot < 0 or seat.slot >= MaxPlayers:
      raise newException(CtfError,
        "player seats document has an out-of-range slot: " & $seat.slot)
    seat.filePath = pathFromCogameUri(entry{"file_uri"}.getStr(""), "file_uri")
    seat.logPath = pathFromCogameUri(entry{"log_uri"}.getStr(""), "log_uri")
    seat.artifactPath = pathFromCogameUri(
      entry{"artifact_uri"}.getStr(""), "artifact_uri")
    seat.contentHash = entry{"content_hash"}.getStr("")
    seat.sizeBytes = entry{"size_bytes"}.getInt(0)
    if seat.filePath.len == 0 or seat.logPath.len == 0:
      raise newException(CtfError,
        "player seats document slot " & $seat.slot & " lacks file_uri/log_uri")
    hostedRuntime.seats.add(seat)
  if hostedRuntime.seats.len == 0:
    raise newException(CtfError, "player seats document seats no one")
  echo "hosted seats: ", hostedRuntime.seats.len, " policy files, host=",
    hostedRuntime.hostBinary

proc timestamp(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc seatToken(config: GameConfig, slot: int): string =
  if slot < config.slots.len: config.slots[slot].token else: ""

proc startHostedSeats*(port: int, config: GameConfig) =
  ## Spawns every seat's policy-host against the now-listening server. The
  ## join carries only slot and token: the server assigns the configured
  ## roster name from the token (configuredPlayerName), exactly as it does
  ## for a platform-hosted pod.
  for seat in hostedRuntime.seats.mitems:
    # The log must exist even if the child never starts (roles/GAME.md).
    createDir(seat.logPath.parentDir)
    writeFile(seat.logPath, "[game] seat " & $seat.slot & " policy file " &
      seat.filePath & " (" & $seat.sizeBytes & " bytes, " & seat.contentHash &
      ") started " & timestamp() & "\n")
    let command = "exec " & quoteShell(hostedRuntime.hostBinary) &
      " --file=" & quoteShell(seat.filePath) &
      " --slot=" & $seat.slot &
      " --url=" & quoteShell("ws://127.0.0.1:" & $port & "/player") &
      " --token=" & quoteShell(config.seatToken(seat.slot)) &
      " >> " & quoteShell(seat.logPath) & " 2>&1"
    try:
      seat.process = startProcess("/bin/sh", args = ["-c", command],
        options = {poParentStreams})
      seat.started = true
    except OSError as error:
      seat.exited = true
      seat.exitCode = 127
      seat.finishedAt = timestamp()
      let handle = open(seat.logPath, fmAppend)
      handle.writeLine("[game] could not start policy-host: " & error.msg)
      handle.close()
      echo "hosted seat ", seat.slot, ": could not start policy-host: ",
        error.msg
  echo "hosted seats: started ", hostedRuntime.seats.len, " policy-host processes"

proc pollHostedSeats*(): seq[tuple[slot, code: int]] =
  ## Newly exited seats since the last poll.
  if not hostedRuntime.enabled:
    return
  for seat in hostedRuntime.seats.mitems:
    if seat.exited:
      if not seat.reported:
        seat.reported = true
        result.add((seat.slot, seat.exitCode))
      continue
    if not seat.started or seat.process == nil:
      continue
    let code = seat.process.peekExitCode()
    if code == -1:
      continue
    seat.exited = true
    seat.exitCode = code
    seat.finishedAt = timestamp()
    seat.reported = true
    seat.process.close()
    echo "hosted seat ", seat.slot, ": policy-host exited with code ", code
    result.add((seat.slot, code))

proc hostedFailureMessage*(slot, code: int): string =
  case code
  of HostedExitInvalidPolicy:
    "player slot " & $slot & ": the policy file is not a valid paintbot-wasm " &
      "policy module (policy-host exit 3; see the seat log)"
  of HostedExitConnect:
    "player slot " & $slot & ": policy-host could not join the lobby"
  else:
    "player slot " & $slot & ": policy-host exited with code " & $code &
      " before the match started"

proc writePlayerStatus() =
  if hostedRuntime.statusPath.len == 0:
    return
  var players = newJArray()
  for seat in hostedRuntime.seats:
    var entry = %*{"slot": seat.slot}
    if not seat.started:
      entry["state"] = %"not_started"
      entry["reason"] = %"policy-host did not start"
    elif seat.exited:
      entry["state"] = %"exited"
      entry["exit_code"] = %seat.exitCode
      let reason =
        case seat.exitCode
        of 0: "Completed"
        of 143, 15: "Completed (stopped at episode end)"
        of HostedExitInvalidPolicy: "Invalid policy module"
        of HostedExitFaulted: "Policy faulted"
        of HostedExitConnect: "Never connected"
        else: "Exited"
      entry["reason"] = %reason
      entry["finished_at"] = %seat.finishedAt
    else:
      entry["state"] = %"running"
    players.add(entry)
  try:
    createDir(hostedRuntime.statusPath.parentDir)
    writeFile(hostedRuntime.statusPath,
      $(%*{"schema_version": "1", "players": players}) & "\n")
  except CatchableError as error:
    echo "player_status.json write failed: ", error.msg

proc finishHostedSeats*() =
  ## Stops every child still running, then records player_status.json.
  ## Called before results.json is written: the seat logs are the children's
  ## stdout, so once they have exited the logs are complete.
  if not hostedRuntime.enabled:
    return
  discard pollHostedSeats()
  var running = false
  for seat in hostedRuntime.seats:
    if seat.started and not seat.exited:
      running = true
      try: seat.process.terminate()
      except CatchableError: discard
  if running:
    let deadline = epochTime() + HostedTerminateGraceMs.float / 1000.0
    while epochTime() < deadline:
      discard pollHostedSeats()
      var stillRunning = false
      for seat in hostedRuntime.seats:
        if seat.started and not seat.exited:
          stillRunning = true
      if not stillRunning:
        break
      sleep(50)
    for seat in hostedRuntime.seats.mitems:
      if seat.started and not seat.exited:
        try: seat.process.kill()
        except CatchableError: discard
    discard pollHostedSeats()
  for seat in hostedRuntime.seats:
    try:
      let handle = open(seat.logPath, fmAppend)
      handle.writeLine("[game] seat " & $seat.slot & " finished " & timestamp() &
        (if seat.exited: " exit=" & $seat.exitCode else: " (killed)"))
      handle.close()
    except CatchableError:
      discard
  writePlayerStatus()
  hostedRuntime.enabled = false
