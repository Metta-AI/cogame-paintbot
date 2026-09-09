## The classic Paintbot baseline (players/baseline) as a paintbot-wasm policy:
## a Sprite v1 mask bot for the campaign's 1v1 / 2v2 / 4ffa cells. The
## websocket receive loop is inverted into the SDK's on-message: every
## server frame becomes one `onMessage` on the deterministic BaselineComponent
## and its changed input mask goes back through `send`.

import policy
import baseline
import baseline/protocols

var component: BaselineComponent

definePolicy:
  component = initBaselineComponent(slot)
  # Sprites Off (0x87) first: the bot never reads pixels, and the server
  # strips them from every frame that follows. Queued before the socket
  # exists; the host flushes it right after the join.
  discard send(spritesOffBlob())
  log("classic baseline slot " & $slot)
do:
  for reply in component.onMessage(message):
    discard send(reply)
