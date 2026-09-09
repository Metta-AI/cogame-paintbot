## policy-host: runs ONE wasm policy module as a Paintbot Season 2 play seat.
##
## The game-hosted runtime (docs/POLICY_WASM.md) spawns one of these per seat.
## It loads the seat's file, runs `policy_init`, connects to the game's own
## /player websocket over loopback, and pumps: every server->seat binary
## message becomes one `policy_on_message` call; everything the guest `send`s
## during that call is written to the socket after it returns. Stdout and
## stderr are the seat log (the game points them at `log_uri`).
##
## Exit codes (the game reads them, docs/POLICY_WASM.md):
##   0  the socket closed after a completed session (match over)
##   2  usage or unreadable file
##   3  the policy is invalid: it failed to compile, instantiate, or init —
##      declared to the platform as that seat's GamePlayerFailure when it
##      happens before the match starts
##   4  the policy faulted mid-session (trap, budget, bad host call)
##   5  the seat never connected within --connect-timeout
##
## The same binary is a platform-hosted player when COWORLD_PLAYER_WS_URL is
## set, which is how a policy author tests a module against a plain game
## container without the game-hosted runner.

import std/[locks, monotimes, os, parseopt, strutils, times, uri]
import whisky
import policy/[llm_proxy, wasi_host]

const
  DefaultConnectTimeoutSeconds = 180
  ConnectRetryMs = 250
  OpPlayView = 0xB1'u8

type
  Options = object
    file: string
    slot: int
    url: string
    token: string
    name: string
    connectTimeoutSeconds: int

  InboundKind = enum
    ibMessage, ibClosed

  Inbound = object
    kind: InboundKind
    data: string

var
  inbox: Channel[Inbound]
  sendLock: Lock
  socketPtr: pointer   ## the WebSocket, owned by the main thread

proc logLine(text: string) =
  stdout.write("[policy-host] ", text, "\n")
  stdout.flushFile()

proc usage(): string =
  """policy-host --file=<policy.wasm> --slot=<N> --url=<ws://host:port/player> --token=<T>
             [--name=<display name>] [--connect-timeout=<seconds>]
Env fallback: COWORLD_PLAYER_WS_URL (a complete player URL with slot and token)."""

proc parseOptions(): Options =
  result.connectTimeoutSeconds = DefaultConnectTimeoutSeconds
  result.slot = -1
  for kind, key, value in getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "file": result.file = value
      of "slot": result.slot = parseInt(value)
      of "url": result.url = value
      of "token": result.token = value
      of "name": result.name = value
      of "connect-timeout": result.connectTimeoutSeconds = parseInt(value)
      of "help", "h":
        echo usage()
        quit(0)
      else:
        stderr.writeLine("unknown option: " & key)
        stderr.writeLine(usage())
        quit(2)
    of cmdArgument:
      stderr.writeLine("unexpected argument: " & key)
      quit(2)
    of cmdEnd: discard
  if result.url.len == 0:
    result.url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if result.file.len == 0:
    result.file = getEnv("POLICY_FILE")
  if result.file.len == 0 or result.url.len == 0:
    stderr.writeLine(usage())
    quit(2)

proc queryValue(url, key: string): string =
  let q = url.find('?')
  if q < 0:
    return ""
  for pair in url[q + 1 .. ^1].split('&'):
    let eq = pair.find('=')
    if eq > 0 and pair[0 ..< eq] == key:
      return pair[eq + 1 .. ^1]

proc addQuery(url, key, value: string): string =
  ## Values are percent-encoded: a roster name such as "Starter (2)" or
  ## "coworld-smoke/cow_...:v1" would otherwise break the request line and
  ## the server drops the handshake without a response.
  if value.len == 0 or queryValue(url, key).len > 0:
    return url
  url & (if '?' in url: "&" else: "?") & key & "=" & encodeUrl(value, usePlus = false)

proc playerUrl(options: Options): string =
  ## Completes the player URL: a bare host:port/player gets slot, token, and
  ## name; a full COWORLD_PLAYER_WS_URL passes through untouched.
  result = options.url
  if "://" notin result:
    result = "ws://" & result
  let scheme = result.find("://") + 3
  if result.find('/', scheme) < 0 and result.find('?', scheme) < 0:
    result &= "/player"
  if options.slot >= 0:
    result = result.addQuery("slot", $options.slot)
  result = result.addQuery("token", options.token)
  result = result.addQuery("name", options.name)

proc sendFrame(data: string, kind: MessageKind) =
  let ws = cast[WebSocket](socketPtr)
  withLock sendLock:
    ws.send(data, kind)

proc readerMain(arg: pointer) {.thread.} =
  ## Owns every receive on the socket so the main thread can block inside a
  ## guest call (a model roundtrip) without the socket backing up.
  let ws = cast[WebSocket](arg)
  try:
    while true:
      let message = ws.receiveMessage(-1)
      if message.isNone:
        continue
      let item = message.get
      case item.kind
      of BinaryMessage:
        inbox.send(Inbound(kind: ibMessage, data: item.data))
      of Ping:
        {.gcsafe.}:
          sendFrame(item.data, Pong)
      of TextMessage, Pong:
        discard
  except CatchableError as error:
    inbox.send(Inbound(kind: ibClosed, data: error.msg))
  except Exception as error:
    inbox.send(Inbound(kind: ibClosed, data: error.msg))

proc connectWithRetry(url: string, timeoutSeconds: int): WebSocket =
  let deadline = getMonoTime() + initDuration(seconds = timeoutSeconds)
  var lastError = ""
  while getMonoTime() < deadline:
    try:
      return newWebSocket(url)
    except CatchableError as error:
      lastError = error.msg
      sleep(ConnectRetryMs)
  raise newException(IOError,
    "could not connect within " & $timeoutSeconds & "s: " & lastError)

proc drainBatch(first: Inbound): seq[Inbound] =
  ## Everything already queued, so stale view frames can be dropped in favor
  ## of the newest one — the server redelivers unacknowledged statuses, so
  ## skipping a view loses nothing the seat cannot recover.
  result.add(first)
  while true:
    let (ok, item) = inbox.tryRecv()
    if not ok:
      break
    result.add(item)

proc main() =
  let options = parseOptions()
  initLock(sendLock)
  inbox.open()

  let slot =
    if options.slot >= 0: options.slot
    else:
      let fromUrl = queryValue(options.url, "slot")
      if fromUrl.len > 0: parseInt(fromUrl) else: 0
  var moduleBytes: string
  try:
    moduleBytes = readFile(options.file)
  except CatchableError as error:
    logLine("cannot read policy file " & options.file & ": " & error.msg)
    quit(2)
  logLine("policy file " & options.file & " (" & $moduleBytes.len &
    " bytes) slot=" & $slot & " wasmtime=" & wasmtimeVersionString())

  let llm = newLlmProxy(slot)
  logLine("llm route: " & llm.describe())

  var runtime: PolicyRuntime
  try:
    runtime = newPolicyRuntime(moduleBytes, llm,
      proc(level: int32, text: string) {.gcsafe.} =
        stdout.write("[policy ", level, "] ", text, "\n")
        stdout.flushFile())
    runtime.init(slot)
  except PolicyRuntimeError as error:
    logLine("INVALID POLICY: " & error.msg)
    quit(3)
  # Replies queued during policy_init (before the socket exists) go out
  # right after the connect.
  var pending = runtime.takeOutbox()
  logLine("policy initialized; " & $pending.len & " packet(s) queued")

  let url = options.playerUrl()
  var ws: WebSocket
  try:
    ws = connectWithRetry(url, options.connectTimeoutSeconds)
  except CatchableError as error:
    logLine("CONNECT FAILED: " & error.msg)
    runtime.close()
    quit(5)
  socketPtr = cast[pointer](ws)
  logLine("connected " & url)
  for packet in pending:
    sendFrame(packet, BinaryMessage)
  pending.setLen(0)

  var reader: Thread[pointer]
  createThread(reader, readerMain, cast[pointer](ws))

  var
    delivered = 0
    skippedViews = 0
    sent = 0
    exitCode = 0
    closedReason = ""
  block pump:
    while true:
      let batch = drainBatch(inbox.recv())
      for index, item in batch:
        case item.kind
        of ibClosed:
          closedReason = item.data
          break pump
        of ibMessage:
          if item.data.len > 0 and uint8(item.data[0]) == OpPlayView:
            var newer = false
            for later in batch[index + 1 .. ^1]:
              if later.kind == ibMessage and later.data.len > 0 and
                  uint8(later.data[0]) == OpPlayView:
                newer = true
                break
            if newer:
              inc skippedViews
              continue
          try:
            runtime.onMessage(item.data)
          except PolicyFault as error:
            logLine("POLICY FAULT: " & error.msg)
            exitCode = 4
            break pump
          inc delivered
          for packet in runtime.takeOutbox():
            try:
              sendFrame(packet, BinaryMessage)
              inc sent
            except CatchableError as error:
              closedReason = "send failed: " & error.msg
              break pump

  logLine("session over: delivered=" & $delivered & " skippedViews=" &
    $skippedViews & " sent=" & $sent & " llmCalls=" & $runtime.llmCalls &
    (if closedReason.len > 0: " (" & closedReason & ")" else: ""))
  ws.close()
  runtime.close()
  quit(exitCode)

when isMainModule:
  main()
