## Drives the starter policy natively through synthetic play-seat packets and
## checks what it puts on the wire: the playbook uploads (one per tick), the
## pre-call and opening call, maintenance re-sends, and status acks.

import std/[json, sequtils, strutils, unittest]
import ../policy_sdk/[policy, wire]
import ../src/shell/canonical
import ../policies/wasm/starter/[ladder, plays]
import ../policies/wasm/starter/starter as starterModule

const
  ContextJson = """{"gun_range":1300,"map":{"height":1200,"name":"brpool16","width":2000},"mode":"br","roster":[{"control":"play","name":"Alpha","seat":0,"team":"red"},{"control":"play","name":"Beta","seat":1,"team":"blue"},{"control":"play","name":"Alpha (2)","seat":2,"team":"green"}],"schema":"play_context","self":{"seat":0,"team":"red"},"v":1,"view_interval":6}"""

proc contextPacket(): string =
  var s = ""
  s.add(char(OpPlayContext)); s.add(char(1))
  let control = "{}"
  for shift in countup(0, 24, 8): s.add(char((control.len shr shift) and 0xff))
  s.add(control)
  for shift in countup(0, 24, 8): s.add(char((ContextJson.len shr shift) and 0xff))
  s.add(ContextJson)
  s

proc viewPacket(tick: uint32, statuses: string, view: string): string =
  var s = ""
  s.add(char(OpPlayView)); s.add(char(1))
  for shift in countup(0, 24, 8): s.add(char((tick shr shift) and 0xff))
  let control = "{\"counters\":{},\"gen\":\"1\",\"schema\":\"control_view\"" &
    (if statuses.len > 0: ",\"statuses\":[" & statuses & "]" else: "") & ",\"v\":1}"
  for shift in countup(0, 24, 8): s.add(char((control.len shr shift) and 0xff))
  s.add(control)
  for shift in countup(0, 24, 8): s.add(char((view.len shr shift) and 0xff))
  s.add(view)
  s

proc feed(message: string): seq[string] =
  sentPackets.setLen(0)
  doAssert policy_on_message(cast[GuestPtr](cast[uint](unsafeAddr message[0])),
    int32(message.len)) == 0
  sentPackets

proc opcodes(packets: seq[string]): seq[int] =
  for p in packets: result.add(int(uint8(p[0])))

suite "starter policy on the wire":
  test "context uploads the playbook one module per tick and calls once ready":
    doAssert policy_init(0) == 0
    var sent = feed(contextPacket())
    check sent.len == 1
    check int(uint8(sent[0][0])) == int(OpModuleUpload)
    var ordinal = 1
    var uploaded = 1
    var opening: seq[string]
    for tick in 1 .. 40:
      let statuses = "{\"kind\":\"module_accepted\",\"ordinal\":\"" & $ordinal &
        "\",\"upload_id\":\"" & $uploaded & "\"},{\"kind\":\"module_ready\",\"ordinal\":\"" &
        $(ordinal + 1) & "\",\"upload_id\":\"" & $uploaded & "\",\"name\":\"" &
        "x\",\"sha256\":\"0\"}"
      ordinal += 2
      # name the module after the upload order the policy chose
      sent = feed(viewPacket(uint32(tick), statuses.replace("\"name\":\"x\"",
        "\"name\":\"" & (["edge_ride", "loot", "scatter", "supply_run", "bodyguard",
        "crossfire", "jackal", "pact", "target_law"])[uploaded - 1] & "\""), ""))
      if sent.opcodes.contains(int(OpModuleUpload)):
        inc uploaded
      if sent.opcodes.contains(int(OpPlayCall)):
        opening = sent
        break
    check uploaded == 9
    check opening.opcodes.count(int(OpPlayCall)) == 2   # pre-call + opening
    check opening.opcodes.contains(int(OpLobbyChatSend))
    check opening.opcodes.contains(int(OpStatusAck))
    # the opening call is canonical JSON with the clone pact injected
    var calls: seq[string]
    for p in opening:
      if uint8(p[0]) == OpPlayCall:
        calls.add(p[14 .. ^1])
    let node = parseJson(calls[1])
    check canonicalJson(node) == calls[1]
    check calls[1].contains("\"seat:2\"")        # Alpha (2) is a clone
    check calls[1].contains("\"play\":\"scatter\"")  # spawn-phase base
  test "manifest defaults exist for every default-bearing param":
    check paramDefault("edge_ride", "margin").getInt == 220
    check paramDefault("bodyguard", "leash")[1].getInt == 220
    check paramDefault("target_law", "holdTrigger") == nil
