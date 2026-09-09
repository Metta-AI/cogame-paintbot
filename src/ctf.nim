import
  std/[json, os, sysrand],
  bitworld/runtime,
  ctf/sim,
  ctf/server,
  ctf/hosted,
  shell/runtime_boot

const LegacyFixedSeed = 0xA6019
  ## The old compiled-in default seed. Hosted variant configs historically
  ## pinned this exact value, so it doubles as the "nobody chose a seed"
  ## sentinel: a config carrying it (or no seed at all) gets a fresh random
  ## seed — with a public fixed seed the GV25 random respawn draws would be
  ## pre-computable by opponents.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed other than the
  ## legacy default (fixture recordings, A/B batteries, forensic re-runs).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false  # config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(CtfError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  ## Drops the legacy sentinel seed from an unpinned config so it cannot
  ## clobber the randomized seed injected before config.update.
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson  # config.update reports the real parse error.

proc limitText(value: int): string =
  ## Returns a readable text value for a numeric limit.
  if value > 0:
    $value
  else:
    "infinite"

proc slotControlCounts(config: GameConfig): (int, int, int) =
  ## Counts play/input configured slots plus unconfigured slots for startup
  ## visibility. `none` is not a SlotControl enum arm; it is the empty roster
  ## tail up to MaxPlayers.
  for slot in config.slots:
    case slot.control
    of scPlay:
      inc result[0]
    of scInput:
      inc result[1]
  result[2] = max(0, MaxPlayers - config.slots.len)

proc echoStartupConfig(
  config: GameConfig,
  runtimeConfig: RuntimeConfig
) =
  ## Prints the effective startup config without token secrets.
  let (playSlots, inputSlots, noneSlots) = config.slotControlCounts()
  echo "CTF config: host=", runtimeConfig.host,
    " port=", runtimeConfig.port,
    " seed=", config.seed,
    " speed=", config.speed, "x",
    " season2Shell=", config.season2Shell,
    " minPlayers=", config.minPlayers,
    " slots=", config.slots.len,
    " slotControls=play:", playSlots, "/input:", inputSlots, "/none:", noneSlots,
    " maxTicks=", config.maxTicks.limitText(),
    " maxGames=", config.maxGames.limitText(),
    " map=", config.mapPath

when isMainModule:
  let
    runtimeConfig = readRuntimeConfig()
    localReplayPath =
      if runtimeConfig.replayUri.len > 0:
        getTempDir() / ("ctf-replay-" & $getCurrentProcessId() &
          ".bitreplay")
      else:
        ""

  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    ## Randomize BEFORE parsing: config.update resolves everything
    ## seed-derived — the terrain pick and its replay-pinned mapSpec, and
    ## the map-default gun range — so the randomized seed must already be
    ## in place or every process would draw the same pool map.
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    echo "seed not pinned; randomized"
  config.echoStartupConfig(runtimeConfig)
  echo "Using map file: " & config.mapPath

  let loadReplayPath =
    if runtimeConfig.replayMode:
      let path = getTempDir() / ("ctf-load-replay-" &
        $getCurrentProcessId() & ".bitreplay")
      writeFile(path, runtimeConfig.replay)
      path
    else:
      ""

  if loadReplayPath.len == 0:
    config.checkDeprecatedMode()
    config.checkPlayRuntimeAvailable()

  if hostedSeatsEnabled():
    loadHostedSeats()

  echo "starting ctf on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    runServerLoop(
      runtimeConfig.host,
      runtimeConfig.port,
      config,
      localReplayPath,
      loadReplayPath,
      "",
      runtimeConfig
    )
  finally:
    # An aborted episode (lobby timeout, a declared player failure) must not
    # leave policy-host children behind or an unwritten player_status.json.
    finishHostedSeats()
