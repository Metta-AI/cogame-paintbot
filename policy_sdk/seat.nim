## Event-driven play-seat bookkeeping for a policy module: the protocol state
## the PoC client keeps (upload/proposal id floors, the status ack mark, the
## context, the latest view, heard chat), driven one server packet at a time.

import std/[json, strutils, tables]
import ./wire, ./policy

type
  SeatEventKind* = enum
    seContext        ## 0xB0 arrived (or re-arrived after a rebind)
    seView           ## 0xB1 with a gameplay payload
    seControlOnly    ## 0xB1 with no payload (lobby, or dead)
    seChat           ## 0xB2
    seStatus         ## one status entry (module_*, call_*, faults)

  SeatEvent* = object
    kind*: SeatEventKind
    status*: JsonNode        ## for seStatus: the raw entry
    statusKind*: string
    chatSeat*: int
    chatText*: string

  PlaySeat* = object
    slot*: int
    nextUploadId*: uint64
    nextProposalId*: uint64
    ackMark*: uint64
    highestOrdinal*: uint64
    context*: JsonNode
    controlContext*: JsonNode
    view*: JsonNode
    viewTick*: uint32
    lastControl*: JsonNode
    uploadNames*: Table[uint64, string]
    readyModules*: seq[string]
    rejectedModules*: seq[string]
    callLabels*: Table[uint64, string]
    acceptedCalls*: int
    rejectedCalls*: int
    statusesSeen*: int
    chatHeard*: int
    uploadQueue: seq[tuple[name, wasm: string]]
    uploadInFlight: bool

proc initPlaySeat*(slot: int): PlaySeat =
  PlaySeat(slot: slot, nextUploadId: 1, nextProposalId: 1,
    context: nil, view: nil)

proc str(node: JsonNode, key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key):
    let value = node[key]
    case value.kind
    of JString: value.getStr
    of JInt: $value.getInt
    of JFloat: $value.getFloat
    of JBool: $value.getBool
    else: $value
  else:
    ""

proc parseU64(text: string): uint64 =
  try:
    result = uint64(parseBiggestUInt(text))
  except ValueError:
    result = 0

proc fileStatus(seat: var PlaySeat, entry: JsonNode, events: var seq[SeatEvent]) =
  inc seat.statusesSeen
  let ordinal = parseU64(entry.str("ordinal"))
  if ordinal > seat.highestOrdinal:
    seat.highestOrdinal = ordinal
  let kind = entry.str("kind")
  case kind
  of "module_accepted":
    seat.uploadInFlight = false
  of "module_ready":
    let uploadId = parseU64(entry.str("upload_id"))
    let name = entry.str("name")
    if name.len > 0 and name notin seat.readyModules:
      seat.readyModules.add(name)
    if uploadId in seat.uploadNames:
      seat.uploadNames.del(uploadId)
  of "module_rejected":
    seat.uploadInFlight = false
    let uploadId = parseU64(entry.str("upload_id"))
    let name = seat.uploadNames.getOrDefault(uploadId, "?")
    seat.rejectedModules.add(name & ": " & entry.str("reason"))
    seat.uploadNames.del(uploadId)
  of "call_accepted":
    inc seat.acceptedCalls
    seat.callLabels.del(parseU64(entry.str("proposal_id")))
  of "call_rejected":
    inc seat.rejectedCalls
    seat.callLabels.del(parseU64(entry.str("proposal_id")))
  else:
    discard
  events.add(SeatEvent(kind: seStatus, status: entry, statusKind: kind))

proc fileControl(seat: var PlaySeat, control: string,
                 events: var seq[SeatEvent]) =
  if control.len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(control)
  except CatchableError:
    return
  seat.lastControl = node
  if node.kind == JObject and node.hasKey("statuses") and
      node["statuses"].kind == JArray:
    for entry in node["statuses"]:
      let ordinal = parseU64(entry.str("ordinal"))
      # Unacked statuses are redelivered every frame; file each once.
      if ordinal > 0 and ordinal <= seat.highestOrdinal:
        continue
      seat.fileStatus(entry, events)

proc handle*(seat: var PlaySeat, message: string): seq[SeatEvent] =
  ## Files one server->seat message and reports what it carried.
  let packet = decodeServerPacket(message)
  case packet.kind
  of spOther:
    discard
  of spPlayContext:
    try:
      seat.context = parseJson(packet.payload)
      seat.controlContext = parseJson(packet.control)
      # A rebind's context carries the acknowledged mark; resume from it.
      let mark = parseU64(seat.controlContext.str("ack_mark"))
      if mark > seat.ackMark:
        seat.ackMark = mark
        seat.highestOrdinal = max(seat.highestOrdinal, mark)
      let floors = seat.controlContext{"floors"}
      if floors != nil:
        seat.nextUploadId = max(seat.nextUploadId,
          parseU64(floors.str("upload_id")) + 1)
        seat.nextProposalId = max(seat.nextProposalId,
          parseU64(floors.str("proposal_id")) + 1)
    except CatchableError as error:
      log("bad 0xB0 payload: " & error.msg, 2)
      return
    result.add(SeatEvent(kind: seContext))
  of spPlayView:
    seat.viewTick = packet.tick
    seat.fileControl(packet.control, result)
    if packet.payload.len > 0:
      try:
        seat.view = parseJson(packet.payload)
        result.add(SeatEvent(kind: seView))
      except CatchableError as error:
        log("bad 0xB1 view payload: " & error.msg, 2)
    else:
      result.add(SeatEvent(kind: seControlOnly))
  of spLobbyChat:
    inc seat.chatHeard
    result.add(SeatEvent(kind: seChat, chatSeat: packet.seat,
      chatText: packet.payload))

proc ackStatuses*(seat: var PlaySeat) =
  ## Acknowledge exactly the ordinals consumed so far, only when they advance.
  if seat.highestOrdinal > seat.ackMark:
    seat.ackMark = seat.highestOrdinal
    discard send(encodeStatusAck(seat.ackMark))

proc sendUpload(seat: var PlaySeat, name, wasm: string): uint64 =
  result = seat.nextUploadId
  inc seat.nextUploadId
  seat.uploadNames[result] = name
  seat.uploadInFlight = true
  discard send(encodeModuleUpload(result, wasm))

proc pumpUploads*(seat: var PlaySeat) =
  ## The server admits ONE upload per seat per tick (per_tick_upload_cap),
  ## so queued modules go out one at a time, each after the previous one's
  ## admission status arrived. Call it after handling every message.
  if seat.uploadInFlight or seat.uploadQueue.len == 0:
    return
  let next = seat.uploadQueue[0]
  seat.uploadQueue.delete(0)
  discard seat.sendUpload(next.name, next.wasm)

proc upload*(seat: var PlaySeat, name, wasm: string) =
  ## Queues one module; `pumpUploads` sends it when the wire allows.
  seat.uploadQueue.add((name, wasm))
  seat.pumpUploads()

proc uploadsPending*(seat: PlaySeat): bool =
  seat.uploadInFlight or seat.uploadQueue.len > 0

proc call*(seat: var PlaySeat, ladderJson: string, label = "call"): uint64 =
  ## Sends one 0xA1 PlayCall with canonical ladder JSON.
  result = seat.nextProposalId
  inc seat.nextProposalId
  seat.callLabels[result] = label
  discard send(encodePlayCall(result, ladderJson))

proc lobbyChat*(seat: PlaySeat, text: string) =
  var line = text
  if line.len > LobbyChatMaxBytes:
    line.setLen(LobbyChatMaxBytes)
  discard send(encodeLobbyChat(line))

proc shout*(seat: PlaySeat, text: string) =
  discard send(encodeShout(text))

proc selfAlive*(seat: PlaySeat): bool =
  seat.view != nil and seat.view.kind == JObject and
    seat.view{"self", "alive"} != nil and seat.view{"self", "alive"}.getBool(true)

proc describeStatus*(entry: JsonNode): string =
  ## One log line per status: kind plus the ids and reason it carries.
  result = entry.str("kind")
  for key in ["ordinal", "upload_id", "proposal_id", "name", "epoch", "tick",
              "entry_id", "code", "reason"]:
    let value = entry.str(key)
    if value.len > 0:
      result.add(" " & key & "=" & value)
