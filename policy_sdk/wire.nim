## The Season 2 play-seat packets (docs/designs/strategy-play-calling-shell
## §4.3), guest-side. Layout-compatible with src/shell/packets.nim; kept
## dependency-free so a policy module carries no engine code.

const
  ShellProtocolVersion* = 1'u8
  OpModuleUpload* = 0xA0'u8
  OpPlayCall* = 0xA1'u8
  OpStatusAck* = 0xA2'u8
  OpLobbyChatSend* = 0xA3'u8
  OpPlayContext* = 0xB0'u8
  OpPlayView* = 0xB1'u8
  OpLobbyChatBroadcast* = 0xB2'u8
  OpSpriteChat* = 0x81'u8
  MaxModuleBytes* = 262144
  MaxCallBytes* = 4096
  LobbyChatMaxBytes* = 512

type
  ServerPacketKind* = enum
    spOther, spPlayContext, spPlayView, spLobbyChat

  ServerPacket* = object
    kind*: ServerPacketKind
    tick*: uint32
    control*: string       ## control JSON (context and view)
    payload*: string       ## context JSON, view JSON, or chat text
    ordinal*: uint64
    seat*: int
    team*: int

proc putU8(s: var string, value: uint8) = s.add(char(value))
proc putU32(s: var string, value: uint32) =
  for shift in countup(0, 24, 8): s.putU8(uint8((value shr shift) and 0xff))
proc putU64(s: var string, value: uint64) =
  for shift in countup(0, 56, 8): s.putU8(uint8((value shr shift) and 0xff))

proc encodeModuleUpload*(uploadId: uint64, wasm: string): string =
  result = newStringOfCap(14 + wasm.len)
  result.putU8(OpModuleUpload)
  result.putU8(ShellProtocolVersion)
  result.putU64(uploadId)
  result.putU32(uint32(wasm.len))
  result.add(wasm)

proc encodePlayCall*(proposalId: uint64, callBytes: string): string =
  result = newStringOfCap(14 + callBytes.len)
  result.putU8(OpPlayCall)
  result.putU8(ShellProtocolVersion)
  result.putU64(proposalId)
  result.putU32(uint32(callBytes.len))
  result.add(callBytes)

proc encodeStatusAck*(mark: uint64): string =
  result = newStringOfCap(16)
  result.putU8(OpStatusAck)
  result.putU8(ShellProtocolVersion)
  for _ in 0 ..< 6: result.putU8(0)
  result.putU64(mark)

proc encodeLobbyChat*(text: string): string =
  result = newStringOfCap(6 + text.len)
  result.putU8(OpLobbyChatSend)
  result.putU8(ShellProtocolVersion)
  result.putU32(uint32(text.len))
  result.add(text)

proc encodeShout*(text: string): string =
  ## The legacy Sprite v1 chat packet (0x81): an in-match shout.
  result = newStringOfCap(3 + text.len)
  result.putU8(OpSpriteChat)
  result.putU8(uint8(text.len and 0xff))
  result.putU8(uint8((text.len shr 8) and 0xff))
  result.add(text)

proc readU32(s: string, at: int): uint32 =
  for i in 0 ..< 4:
    result = result or (uint32(uint8(s[at + i])) shl (8 * i))

proc readU64(s: string, at: int): uint64 =
  for i in 0 ..< 8:
    result = result or (uint64(uint8(s[at + i])) shl (8 * i))

proc decodeServerPacket*(data: string): ServerPacket =
  ## Decodes 0xB0/0xB1/0xB2; anything else (the Sprite stream, malformed
  ## bytes) is `spOther`.
  result.kind = spOther
  if data.len < 2 or uint8(data[1]) != ShellProtocolVersion:
    return
  case uint8(data[0])
  of OpPlayContext:
    if data.len < 10: return
    let controlLen = int(data.readU32(2))
    if 6 + controlLen + 4 > data.len: return
    let ctxLen = int(data.readU32(6 + controlLen))
    if 10 + controlLen + ctxLen != data.len: return
    result.kind = spPlayContext
    result.control = data[6 ..< 6 + controlLen]
    result.payload = data[10 + controlLen ..< data.len]
  of OpPlayView:
    if data.len < 14: return
    result.tick = data.readU32(2)
    let controlLen = int(data.readU32(6))
    if 10 + controlLen + 4 > data.len: return
    let viewLen = int(data.readU32(10 + controlLen))
    if 14 + controlLen + viewLen != data.len: return
    result.kind = spPlayView
    result.control = data[10 ..< 10 + controlLen]
    result.payload = data[14 + controlLen ..< data.len]
  of OpLobbyChatBroadcast:
    if data.len < 20: return
    let textLen = int(data.readU32(16))
    if 20 + textLen != data.len: return
    result.kind = spLobbyChat
    result.ordinal = data.readU64(2)
    result.tick = data.readU32(10)
    result.seat = int(uint8(data[14]))
    result.team = int(uint8(data[15]))
    result.payload = data[20 ..< data.len]
  else:
    discard
