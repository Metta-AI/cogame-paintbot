## echo: the smallest complete paintbot-wasm policy. It uploads the two
## reference plays it carries, says hello in the lobby, calls an edge_ride
## ladder once both modules are ready, and acknowledges every status. It
## exists to prove the game-hosted pipeline end to end; it is not a player.

import std/json
import policy, seat

const
  EdgeRideWasm = staticRead("../../../play_sdk/.build/edge_ride.wasm")
  PactWasm = staticRead("../../../play_sdk/.build/pact.wasm")
  Ladder = "{\"plays\":[{\"entry_id\":\"ride\",\"params\":{\"coverBias\":0.8,\"enterLead\":120,\"margin\":220},\"play\":\"edge_ride\"}]}"

var
  seatState: PlaySeat
  uploaded = false
  called = false

definePolicy:
  seatState = initPlaySeat(slot)
  log("echo policy ready for slot " & $slot)
do:
  for event in seatState.handle(message):
    case event.kind
    of seContext:
      log("context: mode=" & seatState.context{"mode"}.getStr("?"))
      if not uploaded:
        uploaded = true
        seatState.upload("edge_ride", EdgeRideWasm)
        seatState.upload("pact", PactWasm)
        seatState.lobbyChat("gl hf from echo seat " & $seatState.slot)
    of seStatus:
      log("status " & describeStatus(event.status))
      if not called and seatState.readyModules.len >= 2:
        called = true
        discard seatState.call(Ladder, "opening")
    of seChat:
      log("chat seat=" & $event.chatSeat & " " & event.chatText)
    of seView:
      if seatState.viewTick mod 240 == 0:
        log("view tick=" & $seatState.viewTick & " alive=" & $seatState.selfAlive)
    of seControlOnly:
      discard
  seatState.pumpUploads()
  seatState.ackStatuses()
