## The text the model reasons over (ports of poc_policy.summarize and the
## starters' persona-aware wrappers), plus the re-call snapshot/trigger pair.

import std/[algorithm, json, math, strutils]
import seat
import ./[ladder, persona]

type
  HeardChat* = tuple[seat: int, text: string]

  Snapshot* = object
    hp*: int                 ## -1 unknown
    zonePhase*: int          ## -1 unknown
    aliveTeams*: int         ## -1 unknown
    partnerDead*: bool
    kills*: int
    lastAggressorTick*: int

const HuddleLines = 12

proc seatLabel*(context: JsonNode, seat: int): string =
  let name = seatName(context, seat)
  if name.len > 0: name & " (seat " & $seat & ")" else: "seat " & $seat

proc rosterLines(context: JsonNode): seq[string] =
  if context == nil or context{"roster"} == nil or context{"roster"}.len == 0:
    return
  result.add("Roster (name, seat, team):")
  for row in context{"roster"}:
    if row.kind == JObject:
      result.add("  " & seatLabel(context, row{"seat"}.getInt(-1)) & " -- team " &
        row{"team"}.getStr("?"))

proc huddleLines(context: JsonNode, chat: seq[HeardChat]): seq[string] =
  if chat.len == 0:
    return
  result.add("Huddle so far (most recent last):")
  let start = max(0, chat.len - HuddleLines)
  for index in start ..< chat.len:
    result.add("  " & seatLabel(context, chat[index].seat) & ": " & chat[index].text)

proc num(node: JsonNode): string =
  if node == nil: "?"
  elif node.kind == JInt: $node.getInt
  elif node.kind == JFloat: $node.getFloat
  elif node.kind == JString: node.getStr
  else: $node

proc bearing(src, dst: Pos): string =
  let dx = dst.x - src.x
  let dy = dst.y - src.y
  if abs(dx) < 1 and abs(dy) < 1:
    return "here"
  var parts: seq[string]
  if abs(dy) >= abs(dx) * 0.4142:
    parts.add(if dy < 0: "north" else: "south")
  if abs(dx) >= abs(dy) * 0.4142:
    parts.add(if dx > 0: "east" else: "west")
  parts.join("-")

proc rectCenter(rect: JsonNode): Pos =
  (rect[0].getFloat + rect[2].getFloat / 2, rect[1].getFloat + rect[3].getFloat / 2)

proc inside(pos: Pos, rect: JsonNode): bool =
  pos.x >= rect[0].getFloat and pos.x <= rect[0].getFloat + rect[2].getFloat and
    pos.y >= rect[1].getFloat and pos.y <= rect[1].getFloat + rect[3].getFloat

proc isRect(node: JsonNode): bool =
  node != nil and node.kind == JArray and node.len == 4

proc baseSummary(state: PlaySeat, phase: string, chat: seq[HeardChat],
                 standing: string): seq[string] =
  ## poc_policy.summarize: the tiny text summary the model reasons over.
  let context = state.context
  let map = if context != nil: context{"map"} else: nil
  let roster = if context != nil: context{"roster"} else: nil
  let selfNode = if context != nil: context{"self"} else: nil
  let mySeat = if selfNode != nil: selfNode{"seat"}.getInt(state.slot) else: state.slot
  result = @[
    "Phase: " & phase & ".",
    "Mode: " & (if context != nil: context{"mode"}.getStr("unknown") else: "unknown") & ".",
    "Map: " & (if map != nil: map{"name"}.getStr("?") else: "?") & ", " &
      (if map != nil: num(map{"width"}) else: "?") & "x" &
      (if map != nil: num(map{"height"}) else: "?") & " px.",
    "Seats in the roster: " & $(if roster != nil: roster.len else: 0) & ".",
    "You are " & seatLabel(context, mySeat) & " on team " &
      (if selfNode != nil: selfNode{"team"}.getStr("?") else: "?") & ".",
    "Gun range: " & (if context != nil: num(context{"gun_range"}) else: "?") & " px.",
    "Server tick: " & $state.viewTick & "."]
  if selfNode != nil and selfNode{"duo_partner"} != nil and
      selfNode{"duo_partner"}.kind == JInt:
    result.add("Your duo partner is " &
      seatLabel(context, selfNode{"duo_partner"}.getInt) & ".")
  let rosterBlock = rosterLines(context)
  if rosterBlock.len > 0:
    result.add("")
    result.add(rosterBlock)
  let heard = huddleLines(context, chat)
  if heard.len > 0:
    result.add("")
    result.add(heard)
  result.add("")
  result.add("In chat, address other players by name; they see yours. In the call, seats are always written seat:<N>.")
  if standing.len > 0:
    result.add("")
    result.add("The ladder you already have in force is:")
    result.add(standing)
    result.add("Re-call only what you would actually change, and say in one line what changed and why.")

proc partnerLines(state: PlaySeat, killFeed: seq[JsonNode], partner: int): seq[string] =
  let context = state.context
  let label = seatLabel(context, partner)
  result.add("PARTNER STATUS FIRST -- your duo partner is " & label & ".")
  for kill in killFeed:
    if kill{"victim_seat"}.getInt(-2) == partner:
      result.add("Your partner " & label & " has been ELIMINATED. You are alone now.")
      return
  var track: JsonNode = nil
  if state.view != nil and state.view{"tracks"} != nil:
    for t in state.view{"tracks"}:
      if t{"seat"}.getInt(-2) == partner:
        track = t
  if track == nil:
    result.add("No fresh track on " & label & " -- close the distance until you can see each other.")
  else:
    var line = label & " last seen at " & $track{"pos"} & " (tick " & num(track{"fresh_tick"})
    if track{"hp"} != nil:
      line.add(", hp " & num(track{"hp"}))
    result.add(line & ").")

proc vitalLines(state: PlaySeat): seq[string] =
  let view = state.view
  if view == nil:
    return
  let me = view{"self"}
  if me != nil and me{"hp_frac"} != nil and me{"hp_frac"}.kind in {JInt, JFloat}:
    result.add("Your health: " & $int(round(me{"hp_frac"}.getFloat * 100)) & "% (" &
      (if me{"alive"}.getBool(true): "alive" else: "DOWN") & ").")
  let world = view{"world"}
  let zone = if world != nil: world{"zone"} else: nil
  if zone != nil:
    result.add("Zone phase " & num(zone{"phase"}) & ", dps " & num(zone{"dps"}) &
      ", " & num(zone{"ticks_to_shrink"}) & " ticks to shrink.")
  if world != nil and world{"alive_teams"} != nil:
    result.add("Teams still alive: " & num(world{"alive_teams"}) & ".")

proc killFeedLines(context: JsonNode, killFeed: seq[JsonNode], limit = 5): seq[string] =
  if killFeed.len == 0:
    return @["Kill feed: quiet so far. Nobody has died. Find them."]
  result.add("Kill feed (most recent last):")
  let start = max(0, killFeed.len - limit)
  for index in start ..< killFeed.len:
    let kill = killFeed[index]
    result.add("  tick " & num(kill{"tick"}) & ": " &
      seatLabel(context, kill{"victim_seat"}.getInt(-1)) & " eliminated by team " &
      kill{"killer_team"}.getStr("?") & ".")

proc stateLines(state: PlaySeat): seq[string] =
  ## The live facts every persona reasons over, read straight off the view.
  let view = state.view
  if view == nil:
    return
  let context = state.context
  let selfNode = if context != nil: context{"self"} else: nil
  let mySeat = if selfNode != nil: selfNode{"seat"}.getInt(state.slot) else: state.slot
  let myTeam = if selfNode != nil: selfNode{"team"}.getStr("") else: ""
  let partner = if selfNode != nil and selfNode{"duo_partner"} != nil and
    selfNode{"duo_partner"}.kind == JInt: selfNode{"duo_partner"}.getInt else: -1
  let me = view{"self"}
  let hasPos = me != nil and isPos(me{"pos"})
  let pos = if hasPos: toPos(me{"pos"}) else: (0.0, 0.0)
  let tick = view{"tick"}.getInt(int(state.viewTick))
  result.add("Live state (tick " & $tick & "):")
  if hasPos:
    var line = "  You are at (" & $int(pos.x) & ", " & $int(pos.y) & "), hp " & num(me{"hp"})
    if me{"hp_frac"} != nil and me{"hp_frac"}.kind in {JInt, JFloat}:
      line.add(" (" & $int(round(me{"hp_frac"}.getFloat * 100)) & "%)")
    result.add(line & ".")
  let world = view{"world"}
  let zone = if world != nil: world{"zone"} else: nil
  if zone != nil and isRect(zone{"current"}) and hasPos:
    let cur = zone{"current"}
    let where = if inside(pos, cur): "INSIDE" else: "OUTSIDE (taking zone damage)"
    result.add("  Zone phase " & num(zone{"phase"}) & ": current safe rect x" &
      num(cur[0]) & ".." & $(cur[0].getInt + cur[2].getInt) & " y" & num(cur[1]) &
      ".." & $(cur[1].getInt + cur[3].getInt) & "; you are " & where & ".")
    if isRect(zone{"next"}):
      let nxt = zone{"next"}
      let c = rectCenter(nxt)
      result.add("  Next zone rect x" & num(nxt[0]) & ".." & $(nxt[0].getInt + nxt[2].getInt) &
        " y" & num(nxt[1]) & ".." & $(nxt[1].getInt + nxt[3].getInt) & ", center " &
        $int(dist(pos, c)) & " px to the " & bearing(pos, c) & "; you are " &
        (if inside(pos, nxt): "already inside" else: "NOT yet inside") &
        " it; shrink in " & num(zone{"ticks_to_shrink"}) &
        " ticks (24 ticks = 1 s), zone dps " & num(zone{"dps"}) & ".")
  if world != nil and world{"alive_teams"} != nil:
    result.add("  Teams still alive: " & num(world{"alive_teams"}) & ".")
  var enemies: seq[JsonNode]
  var partnerTrack: JsonNode = nil
  if view{"tracks"} != nil:
    for track in view{"tracks"}:
      if track.kind != JObject or not isPos(track{"pos"}):
        continue
      let seat = track{"seat"}.getInt(-2)
      if partner >= 0 and seat == partner:
        partnerTrack = track
        continue
      if seat == mySeat or (myTeam.len > 0 and track{"team"}.getStr("") == myTeam):
        continue
      enemies.add(track)
  if hasPos:
    enemies.sort(proc(a, b: JsonNode): int =
      cmp(dist(pos, toPos(a{"pos"})), dist(pos, toPos(b{"pos"}))))
  if enemies.len > 0:
    result.add("  Enemies tracked: " & $enemies.len & " (nearest first):")
    for index in 0 ..< min(4, enemies.len):
      let track = enemies[index]
      let age = if track{"fresh_tick"} != nil and track{"fresh_tick"}.kind == JInt:
        $(tick - track{"fresh_tick"}.getInt) else: "?"
      let seen = if hasPos: $int(dist(pos, toPos(track{"pos"}))) & " px " &
        bearing(pos, toPos(track{"pos"})) else: $track{"pos"}
      result.add("    " & seatLabel(context, track{"seat"}.getInt(-1)) & " team " &
        track{"team"}.getStr("?") & ", " & seen & ", hp " & num(track{"hp"}) &
        ", seen " & age & " ticks ago" &
        (if track{"bounty"}.getBool(false): ", BOUNTY" else: "") & ".")
  else:
    result.add("  Enemies tracked: none in view.")
  if partner >= 0 and partnerTrack != nil and hasPos:
    result.add("  Partner " & seatLabel(context, partner) & ": " &
      $int(dist(pos, toPos(partnerTrack{"pos"}))) & " px " &
      bearing(pos, toPos(partnerTrack{"pos"})) & ", hp " & num(partnerTrack{"hp"}) & ".")
  var items: seq[JsonNode]
  if view{"items"} != nil:
    for item in view{"items"}:
      if item.kind == JObject and item{"present"}.getBool(true) and isPos(item{"pos"}):
        items.add(item)
  if hasPos:
    items.sort(proc(a, b: JsonNode): int =
      cmp(dist(pos, toPos(a{"pos"})), dist(pos, toPos(b{"pos"}))))
  if items.len > 0:
    var parts: seq[string]
    for index in 0 ..< min(5, items.len):
      let item = items[index]
      if hasPos:
        parts.add(item{"kind"}.getStr("?") & " " & $int(dist(pos, toPos(item{"pos"}))) &
          " px " & bearing(pos, toPos(item{"pos"})))
      else:
        parts.add(item{"kind"}.getStr("?"))
    result.add("  Items in view: " & parts.join(", ") & ".")
  var recent: seq[JsonNode]
  if view{"aggressors"} != nil:
    for a in view{"aggressors"}:
      if a.kind == JObject and a{"tick"} != nil and a{"tick"}.kind == JInt and
          tick - a{"tick"}.getInt <= 240:
        recent.add(a)
  if recent.len > 0:
    var who: seq[string]
    let start = max(0, recent.len - 3)
    for index in start ..< recent.len:
      let a = recent[index]
      who.add(if a{"seat"} != nil and a{"seat"}.kind == JInt:
        seatLabel(context, a{"seat"}.getInt) else: "an unseen shooter")
    result.add("  You were SHOT AT in the last 10 s by: " & who.join(", ") & ".")
  let hazards = view{"hazards"}
  if hazards != nil and hazards.kind == JObject and hazards{"grenades"} != nil and
      hazards{"grenades"}.kind == JArray and hazards{"grenades"}.len > 0:
    result.add("  Live grenades near you: " & $hazards{"grenades"}.len & ".")

proc matchPhase*(state: PlaySeat): string =
  let view = state.view
  if view == nil:
    return "lobby, before the drop"
  let world = view{"world"}
  let zone = if world != nil: world{"zone"} else: nil
  let teams = if world != nil: num(world{"alive_teams"}) else: "?"
  let teamsInt = if world != nil and world{"alive_teams"} != nil and
    world{"alive_teams"}.kind == JInt: world{"alive_teams"}.getInt else: -1
  let phase = if zone != nil: num(zone{"phase"}) else: "?"
  let phaseInt = if zone != nil and zone{"phase"} != nil and
    zone{"phase"}.kind == JInt: zone{"phase"}.getInt else: -1
  if teamsInt >= 0 and teamsInt <= 3:
    "ENDGAME, " & teams & " teams left, zone phase " & phase
  elif phaseInt >= 0 and phaseInt <= 1:
    "early match, " & teams & " teams alive, zone phase " & phase
  else:
    "mid-match, " & teams & " teams alive, zone phase " & phase & ", the zone is closing"

proc summarize*(state: PlaySeat, phase: string, persona: Persona,
                chat: seq[HeardChat], killFeed: seq[JsonNode],
                standing = "", notes: seq[string] = @[]): string =
  var lines: seq[string]
  let selfNode = if state.context != nil: state.context{"self"} else: nil
  let partner = if selfNode != nil and selfNode{"duo_partner"} != nil and
    selfNode{"duo_partner"}.kind == JInt: selfNode{"duo_partner"}.getInt else: -1
  if persona.partnerFocus and partner >= 0:
    lines.add(partnerLines(state, killFeed, partner))
    lines.add("")
  lines.add(baseSummary(state, phase, chat, standing))
  let vitals = vitalLines(state)
  if vitals.len > 0:
    lines.add("")
    lines.add(vitals)
  let live = stateLines(state)
  if live.len > 0:
    lines.add("")
    lines.add(live)
  if persona.includeKillFeed:
    lines.add("")
    lines.add(killFeedLines(state.context, killFeed))
  if notes.len > 0:
    lines.add("")
    lines.add("Since your last call: " & notes.join("; ") & ".")
  lines.join("\n")

proc snapshot*(state: PlaySeat, killFeed: seq[JsonNode], partner: int): Snapshot =
  ## The facts a re-call trigger compares against.
  result.hp = -1
  result.zonePhase = -1
  result.aliveTeams = -1
  result.lastAggressorTick = -1
  let view = state.view
  if view == nil:
    return
  let me = view{"self"}
  if me != nil and me{"hp"} != nil and me{"hp"}.kind == JInt:
    result.hp = me{"hp"}.getInt
  let world = view{"world"}
  if world != nil:
    let zone = world{"zone"}
    if zone != nil and zone{"phase"} != nil and zone{"phase"}.kind == JInt:
      result.zonePhase = zone{"phase"}.getInt
    if world{"alive_teams"} != nil and world{"alive_teams"}.kind == JInt:
      result.aliveTeams = world{"alive_teams"}.getInt
  if partner >= 0:
    for kill in killFeed:
      if kill{"victim_seat"}.getInt(-2) == partner:
        result.partnerDead = true
  result.kills = killFeed.len
  if view{"aggressors"} != nil:
    for a in view{"aggressors"}:
      if a.kind == JObject and a{"tick"} != nil and a{"tick"}.kind == JInt:
        result.lastAggressorTick = max(result.lastAggressorTick, a{"tick"}.getInt)

proc triggers*(before, now: Snapshot): seq[string] =
  ## Human-readable reasons to re-call, from two snapshots.
  if before.hp >= 0 and now.hp >= 0 and now.hp < before.hp:
    result.add("your hp fell " & $before.hp & " -> " & $now.hp)
  if before.zonePhase != now.zonePhase and now.zonePhase >= 0:
    result.add("zone phase " & $before.zonePhase & " -> " & $now.zonePhase)
  if now.partnerDead and not before.partnerDead:
    result.add("your duo partner was ELIMINATED")
  if now.lastAggressorTick > before.lastAggressorTick:
    result.add("you were shot at")
  if before.aliveTeams >= 0 and now.aliveTeams >= 0 and
      now.aliveTeams < before.aliveTeams:
    result.add("teams alive " & $before.aliveTeams & " -> " & $now.aliveTeams)
  elif now.kills > before.kills:
    result.add($(now.kills - before.kills) & " new kill(s) in the feed")
