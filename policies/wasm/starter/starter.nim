## The starter policy as a paintbot-wasm module: one of the three Season 2
## starter personas (policies/starters/), with the Python harness's blocking
## socket loop inverted into the SDK's on-message events. Build one persona
## per module with -d:persona=cautious|aggressive|collaborative.
##
## Flow (starter_harness.run + _live_loop): upload the playbook one module
## per tick; once every module is ready, send the model-free pre-call
## ladder; one model turn for the opening chat line and call; then the live
## loop on every view: ladder maintenance every ~2 s (gates re-evaluated
## against the view), a model re-call when a trigger lands past the
## persona's spacing (or the periodic check), never past the call budget.

import std/[algorithm, json, sequtils, strutils]
import policy, seat
import ./[brain, ladder, persona, plays, summary]

const
  PersonaName {.strdefine.} = "cautious"
  PlaybookNames = ["edge_ride", "pact", "supply_run", "scatter", "loot",
                   "bodyguard", "crossfire", "jackal", "target_law"]
  TicksPerSecond = 24
  MaintenanceTicks = 2 * TicksPerSecond
  CoordinationDelayTicks = 36        ## > LobbyChatMinSpacingTicks (24)
  MaxPlaybookSummaryCalls = 1

const PlaybookBytes: array[PlaybookNames.len, string] = [
  staticRead("../../../play_sdk/.build/edge_ride.wasm"),
  staticRead("../../../play_sdk/.build/pact.wasm"),
  staticRead("../../../play_sdk/.build/supply_run.wasm"),
  staticRead("../../../play_sdk/.build/scatter.wasm"),
  staticRead("../../../play_sdk/.build/loot.wasm"),
  staticRead("../../../play_sdk/.build/bodyguard.wasm"),
  staticRead("../../../play_sdk/.build/crossfire.wasm"),
  staticRead("../../../play_sdk/.build/jackal.wasm"),
  staticRead("../../../play_sdk/.build/target_law.wasm")]

type
  Stage = enum
    stWaitingContext, stUploading, stOpening, stLive, stDone

  Starter = object
    persona: Persona
    seat: PlaySeat
    brain: Brain
    available: seq[string]
    stage: Stage
    chat: seq[HeardChat]
    killFeed: seq[JsonNode]
    killsSeen: seq[tuple[tick, victim: int]]
    wantedEntries: JsonNode
    standingPayload: string
    firstViewTick: int
    calls: int
    lastCallTick: int
    lastMaintenanceTick: int
    before: Snapshot
    partner: int
    coordinationDueTick: int   ## -1 = none pending
    coordinationText: string
    minGapTicks: int
    periodicTicks: int
    maintained: int
    deadLogged: bool

var starter: Starter

proc buildSystemPrompt(persona: Persona, available: seq[string]): string =
  var parts = @[persona.promptIntro.strip(), "", playbookBrief(available)]
  var notes: seq[string]
  for (play, note) in persona.playNotes:
    if play in available:
      notes.add("- " & note)
  if notes.len > 0:
    parts.add("How YOU use this playbook:")
    parts.add(notes)
    parts.add("")
  parts.add(formatRules(available))
  parts.join("\n")

proc inSpawnPhase(s: var Starter): bool =
  let view = s.seat.view
  if view == nil or view{"tick"} == nil or view{"tick"}.kind != JInt:
    return true
  let tick = view{"tick"}.getInt
  if s.firstViewTick < 0:
    s.firstViewTick = tick
  tick - s.firstViewTick < s.persona.spawnPhaseTicks

proc gateAndBuild(s: var Starter): tuple[payload: string, entries: JsonNode] =
  ## Gate the wanted ladder against the live view and canonicalize it.
  var basePlay = s.persona.basePlay
  let spawn = s.inSpawnPhase()
  if spawn:
    basePlay = if "scatter" in s.available: "scatter" else: "edge_ride"
  var gated = layerLadder(s.wantedEntries, s.seat.view, s.seat.context,
    s.killFeed, basePlay)
  if spawn:
    var kept = newJArray()
    for entry in gated:
      if entry{"play"}.getStr("") notin GatedPlays:
        kept.add(entry)
    gated = kept
  gated = allyClones(gated, s.seat.context)
  buildCall(%*{"call": {"entries": gated}}, s.available)

proc repairCall(s: var Starter, decision: JsonNode): tuple[payload: string, entries: JsonNode] =
  let (_, entries) = buildCall(decision, s.available)
  var adjusted = copy(entries)
  if s.persona.adjustEntries != nil:
    adjusted = s.persona.adjustEntries(adjusted, s.seat.context, s.seat.view)
  s.wantedEntries = copy(adjusted)
  s.gateAndBuild()

proc sendCall(s: var Starter, payload: string, label: string) =
  log("0xA1 " & label & ": " & payload)
  discard s.seat.call(payload, label)
  s.standingPayload = payload

proc snapshotNow(s: Starter): Snapshot =
  snapshot(s.seat, s.killFeed, s.partner)

proc fileKills(s: var Starter) =
  let view = s.seat.view
  if view == nil or view{"kill_feed"} == nil or view{"kill_feed"}.kind != JArray:
    return
  for kill in view{"kill_feed"}:
    if kill.kind != JObject:
      continue
    let key = (kill{"tick"}.getInt(-1), kill{"victim_seat"}.getInt(-1))
    if key notin s.killsSeen:
      s.killsSeen.add(key)
      s.killFeed.add(kill)

proc openingTurn(s: var Starter) =
  ## The pre-call, then model turn 1: chat, coordination, the opening call.
  let seed = if s.persona.cannedTurns.len > 0: s.persona.cannedTurns[0]
    else: %*{"call": {"entries": []}}
  let (prePayload, preEntries) = s.repairCall(seed)
  log("pre-call ladder: " & entryIds(preEntries).join(", "))
  s.sendCall(prePayload, "pre-call")

  let summaryText = summarize(s.seat, "lobby, before the drop", s.persona,
    s.chat, s.killFeed)
  log("model input:\n" & summaryText)
  let decision = s.brain.decide(summaryText)
  log("model output: " & $decision)
  var chatText = decision{"chat"}.getStr("").strip()
  if chatText.len == 0:
    chatText = "gl hf"
  log("0xA3 chat: " & chatText)
  s.seat.lobbyChat(chatText)
  if s.persona.extraChat != nil:
    let extra = s.persona.extraChat(s.seat.context, 1)
    if extra.len > 0:
      s.coordinationText = extra
      s.coordinationDueTick = int(s.seat.viewTick) + CoordinationDelayTicks
  let (payload, _) = s.repairCall(decision)
  s.sendCall(payload, "opening call")
  s.calls = 1
  s.lastCallTick = int(s.seat.viewTick)
  s.before = s.snapshotNow()
  s.stage = stLive
  log("live loop: budget " & $s.persona.maxCalls & " calls, min gap " &
    $(s.minGapTicks div TicksPerSecond) & "s, periodic " &
    $(s.periodicTicks div TicksPerSecond) & "s")

proc liveStep(s: var Starter) =
  let view = s.seat.view
  if view == nil:
    return
  let tick = int(s.seat.viewTick)
  if s.coordinationDueTick >= 0 and tick >= s.coordinationDueTick:
    log("0xA3 coordination: " & s.coordinationText)
    s.seat.lobbyChat(s.coordinationText)
    s.coordinationDueTick = -1
  if not s.seat.selfAlive:
    if not s.deadLogged:
      s.deadLogged = true
      log("seat is dead at tick " & $tick & "; " & $s.calls & " model call(s), " &
        $s.maintained & " maintenance call(s)")
    return
  if tick - s.lastMaintenanceTick >= MaintenanceTicks:
    s.lastMaintenanceTick = tick
    let (gatedPayload, gatedEntries) = s.gateAndBuild()
    if gatedPayload != s.standingPayload:
      log("ladder maintenance at tick " & $tick & ": " &
        entryIds(entriesOfPayload(s.standingPayload)).join(",") & " -> " &
        entryIds(gatedEntries).join(","))
      s.sendCall(gatedPayload, "maintenance")
      inc s.maintained
      s.before = s.snapshotNow()
  if s.calls >= s.persona.maxCalls:
    return
  let elapsed = tick - s.lastCallTick
  if elapsed < s.minGapTicks:
    return
  let now = s.snapshotNow()
  var reasons = triggers(s.before, now)
  if reasons.len == 0 and elapsed >= s.periodicTicks:
    reasons.add("periodic check (" & $(elapsed div TicksPerSecond) & " s since your last call)")
  if reasons.len == 0:
    return
  let turn = s.calls + 1
  let summaryText = summarize(s.seat, matchPhase(s.seat), s.persona, s.chat,
    s.killFeed, standing = s.standingPayload, notes = reasons)
  log("re-call " & $(turn - 1) & " trigger: " & reasons.join("; "))
  log("model input:\n" & summaryText)
  let decision = s.brain.decide(summaryText)
  log("model output: " & $decision)
  let chatText = decision{"chat"}.getStr("").strip()
  if chatText.len > 0:
    log("(mid-match, not sent) chat: " & chatText)
  let (payload, _) = s.repairCall(decision)
  s.sendCall(payload, "re-call " & $(turn - 1))
  inc s.calls
  s.lastCallTick = tick
  s.before = s.snapshotNow()

proc onEvent(s: var Starter, event: SeatEvent) =
  case event.kind
  of seContext:
    let context = s.seat.context
    let selfNode = if context != nil: context{"self"} else: nil
    if selfNode != nil and selfNode{"duo_partner"} != nil and
        selfNode{"duo_partner"}.kind == JInt:
      s.partner = selfNode{"duo_partner"}.getInt
    if s.stage == stWaitingContext:
      log("0xB0 play_context: " & $context)
      # Controllers first: uploads are one per seat per tick, so a truncated
      # run still has a usable ladder driver.
      var order = toSeq(0 ..< PlaybookNames.len)
      order.sort(proc(a, b: int): int =
        let ca = int(playClass(PlaybookNames[a]) != pcController)
        let cb = int(playClass(PlaybookNames[b]) != pcController)
        if ca != cb: cmp(ca, cb) else: cmp(PlaybookNames[a], PlaybookNames[b]))
      for index in order:
        s.seat.upload(PlaybookNames[index], PlaybookBytes[index])
      s.stage = stUploading
  of seStatus:
    log("0xB1 status: " & describeStatus(event.status))
    if s.stage == stUploading and not s.seat.uploadsPending and
        s.seat.readyModules.len + s.seat.rejectedModules.len >= PlaybookNames.len:
      for rejected in s.seat.rejectedModules:
        log("FAILURE: module " & rejected, 3)
      s.available = @[]
      for name in PlaybookNames:
        if name in s.seat.readyModules:
          s.available.add(name)
      if s.available.len == 0:
        log("no module reached module_ready; the seat rides the engine default", 3)
        s.stage = stDone
      else:
        s.brain.systemPrompt = buildSystemPrompt(s.persona, s.available)
        s.stage = stOpening
        s.openingTurn()
  of seChat:
    s.chat.add((event.chatSeat, event.chatText))
    log("0xB2 chat: seat=" & $event.chatSeat & " " & event.chatText)
  of seView:
    s.fileKills()
    if s.stage == stLive:
      s.liveStep()
  of seControlOnly:
    if s.stage == stLive and s.coordinationDueTick >= 0 and
        int(s.seat.viewTick) >= s.coordinationDueTick:
      log("0xA3 coordination: " & s.coordinationText)
      s.seat.lobbyChat(s.coordinationText)
      s.coordinationDueTick = -1

definePolicy:
  starter = Starter(persona: personaNamed(PersonaName), partner: -1,
    firstViewTick: -1, coordinationDueTick: -1, wantedEntries: newJArray())
  starter.seat = initPlaySeat(slot)
  starter.minGapTicks = int(max(1.0, starter.persona.recallSeconds) * TicksPerSecond)
  starter.periodicTicks = int((if starter.persona.periodicSeconds > 0:
    starter.persona.periodicSeconds else: 3.0 * starter.persona.recallSeconds) *
    TicksPerSecond)
  starter.brain = initBrain(starter.persona, "", liveEnabled = true)
  var sizes: seq[string]
  for index, name in PlaybookNames:
    sizes.add(name & " (" & $PlaybookBytes[index].len & "B)")
  log("starter " & starter.persona.name & " slot " & $slot & "; playbook: " &
    sizes.join(", "))
do:
  for event in starter.seat.handle(message):
    starter.onEvent(event)
  starter.seat.pumpUploads()
  starter.seat.ackStatuses()
