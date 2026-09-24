## Persistent numeric training bridge over the certified native Arena runtime.

import std/[base64, hashes, json, os, strutils]
import arena/game_runtime
import baseline
import baseline/protocols
import bitworld/spriteprotocol
import ctf/labels

type
  TrainingBridge = object
    game: ArenaGame
    learner: ProtocolClient
    teachers: seq[BaselineComponent]
    replies: seq[seq[string]]
    heldMasks: seq[uint8]
    frame: string
    tick: int
    decisionId: int
    teams: int

proc multiTeamMask(seat, tick: int): uint8 =
  ## The shipped baseline assumes red/blue roles. Give other teams legal
  ## movement and periodic shots without inventing hidden-state access.
  let directions = [ButtonUp, ButtonRight, ButtonDown, ButtonLeft]
  result = directions[((tick div 16) + seat) mod directions.len]
  if tick mod 12 == seat mod 12:
    result = result or ButtonA

proc current(bridge: TrainingBridge): JsonNode =
  var visible = newJArray()
  for item in bridge.learner.spriteObjects():
    let label = item.label
    if label.startsWith(LabelPrefixSelf) or
        label.startsWith(LabelPrefixPlayer) or
        label.startsWith(LabelPrefixHp) or
        label.startsWith(LabelPrefixLives) or
        label.startsWith(LabelPrefixWeapon) or
        label.startsWith(LabelPrefixOwnAim) or
        label.startsWith(LabelPrefixZone) or
        label.endsWith(" heart") or
        label in [LabelMedKit, LabelShield, LabelFireIcon, LabelFireIconCooldown]:
      visible.add(%*{"label": label, "x": item.x, "y": item.y})
  %*{
    "kind": "decision",
    "game": "paintbot",
    "decision_id": bridge.decisionId,
    "seat": 0,
    "engine_seat": 0,
    "turn": bridge.tick,
    "semantic_view": {"sprite_v1_base64": encode(bridge.frame),
                      "visible_objects": visible},
    "inbox": [],
    "messages": [],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "mask": {"type": "integer", "minimum": 0, "maximum": 255}},
      "required": ["mask"]},
    "typed_question": nil
  }

proc encodeState(bridge: TrainingBridge): JsonNode =
  var
    selfX = 0
    selfY = 0
    alive = 0
    aim = 0
  for item in bridge.learner.spriteObjects():
    if item.label.startsWith(LabelPrefixSelf):
      selfX = item.x + item.width div 2 + bridge.learner.mapCameraX
      selfY = item.y + item.height div 2 + bridge.learner.mapCameraY
      alive = 1
    elif item.label.startsWith(LabelPrefixOwnAim):
      aim = parseInt(item.label[LabelPrefixOwnAim.len .. ^1])
  let values = [
    bridge.tick.float, selfX.float, selfY.float, alive.float, aim.float,
    bridge.learner.spriteObjectsWithLabel(LabelFireIcon).len.float,
    bridge.learner.spriteObjectsWithLabelPrefix(LabelPrefixPlayer).len.float,
    bridge.learner.spriteObjectsWithLabel(LabelMedKit).len.float,
    bridge.learner.spriteObjectsWithLabel(LabelShield).len.float,
    bridge.learner.walkabilityWidth.float,
    bridge.learner.walkabilityHeight.float,
  ]
  var actions = newJArray()
  for mask in 0 .. 255:
    actions.add(%*{"mask": mask})
  %*{"decision_id": bridge.decisionId, "values": values, "actions": actions}

proc reset(bridge: var TrainingBridge, manifest: JsonNode, variant: string,
           maxTicks: int, request: JsonNode): JsonNode =
  var config: JsonNode
  for row in manifest["variants"]:
    if row["id"].getStr() == variant:
      config = row["game_config"].copy()
  assert not config.isNil
  assert not config.hasKey("season2Shell") or not config["season2Shell"].getBool(),
    "Season 2 play seats require the play-call protocol"
  let seats = config["num_agents"].getInt()
  bridge.teams = if config.hasKey("teams"): config["teams"].getInt() else: 2
  assert request["players"].getInt() == seats
  if maxTicks > 0:
    assert maxTicks <= config["maxTicks"].getInt()
    config["maxTicks"] = %maxTicks
    # Classic barrage explicitly disables the draw ceiling. A bounded
    # curriculum must turn it off and skip the post-game replay countdown.
    config["barrageMaxPerSec"] = %0
    config["gameOverTicks"] = %1
  let seed = cast[uint64](hash(request["seed"].getStr()))
  bridge.game = initArenaGame($config, seats, seed)
  bridge.game.sim.gameEventLoggingEnabled = false
  bridge.learner = initProtocolClient()
  bridge.teachers = newSeq[BaselineComponent](seats)
  bridge.replies = newSeq[seq[string]](seats)
  bridge.heldMasks = newSeq[uint8](seats)
  for seat in 0 ..< seats:
    if seat == 0 or bridge.teams == 2:
      bridge.teachers[seat] = initBaselineComponent(seat)
  let first = bridge.game.step([])
  bridge.tick = 1
  for message in first.messages:
    bridge.replies[message.seat] =
      if message.seat == 0 or bridge.teams == 2:
        bridge.teachers[message.seat].onMessage(message.payload)
      else:
        @[inputBlob(multiTeamMask(message.seat, bridge.tick))]
    if bridge.replies[message.seat].len > 0:
      bridge.heldMasks[message.seat] = uint8(bridge.replies[message.seat][0][1])
    if message.seat == 0:
      bridge.frame = message.payload
      bridge.learner.applyFrame(message.payload)
  bridge.decisionId = 0
  bridge.current()

proc step(bridge: var TrainingBridge, request: JsonNode): JsonNode =
  assert request["decision_id"].getInt() == bridge.decisionId
  let answer = parseJson(request["response"].getStr())
  assert answer.kind == JObject and answer.len == 1
  let mask = answer["mask"].getInt()
  assert mask in 0 .. 255
  var packets = @[SeatMessage(seat: 0, payload: inputBlob(uint8(mask)))]
  for seat in 1 ..< bridge.replies.len:
    for reply in bridge.replies[seat]:
      packets.add(SeatMessage(seat: seat, payload: reply))
  let next = bridge.game.step(packets)
  inc bridge.tick
  inc bridge.decisionId
  for message in next.messages:
    bridge.replies[message.seat] =
      if message.seat == 0 or bridge.teams == 2:
        bridge.teachers[message.seat].onMessage(message.payload)
      else:
        @[inputBlob(multiTeamMask(message.seat, bridge.tick))]
    if bridge.replies[message.seat].len > 0:
      bridge.heldMasks[message.seat] = uint8(bridge.replies[message.seat][0][1])
    if message.seat == 0:
      bridge.frame = message.payload
      bridge.learner.applyFrame(message.payload)
  var observation: JsonNode
  if next.done:
    let results = parseJson(bridge.game.finish())
    var scores = newJObject()
    for seat in 0 ..< results["scores"].len:
      scores[$seat] = results["scores"][seat]
    observation = %*{"kind": "terminal", "scores": scores}
  else:
    observation = bridge.current()
  %*{"kind": "accepted", "action": answer, "observation": observation}

when isMainModule:
  assert paramCount() in 2 .. 3,
    "usage: train_bridge MANIFEST VARIANT [MAX_TICKS]"
  let manifestPath = paramStr(1).absolutePath()
  setCurrentDir(getAppFilename().parentDir())
  let manifest = parseFile(manifestPath)
  let variant = paramStr(2)
  let maxTicks = if paramCount() == 3: parseInt(paramStr(3)) else: 0
  var bridge: TrainingBridge
  for line in stdin.lines:
    let request = parseJson(line)
    let reply = case request["kind"].getStr()
      of "reset": bridge.reset(manifest, variant, maxTicks, request)
      of "encode": bridge.encodeState()
      of "teacher": %*{"response": $(%*{"mask": bridge.heldMasks[0]})}
      of "step": bridge.step(request)
      else: raise newException(ValueError, "Unknown bridge request kind")
    echo reply
