## Repair, gating, and canonicalization of ladder calls (port of the
## starters' build_call / layer_ladder / gate_and_build machinery). Works on
## JsonNode entries so persona hooks can reshape them freely; the result is
## always re-repaired, so a hook can only narrow, never break.

import std/[algorithm, json, math, strutils]
import canonical
import ./plays

const
  MaxSeat* = 31
  MaxActiveOverlays* = 2
  MaxLadderEntries* = 16
  MaxCallBytes* = 4096
  EntryIdChars = {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}
  MaxHpFallback* = 6.0
  TrackFreshTicks* = 240
  LootClearPx* = 500.0
  GatedPlays* = ["supply_run", "loot", "bodyguard", "jackal", "crossfire"]

type
  Pos* = tuple[x, y: float]

  ViewFacts* = object
    hasPos*: bool
    pos*: Pos
    hpFrac*: float
    hasHpFrac*: bool
    maxHp*: float
    enemies*: seq[JsonNode]
    items*: seq[JsonNode]
    hasNearestEnemy*: bool
    nearestEnemy*: float
    partner*: int          ## -1 when none
    partnerDead*: bool
    partnerTrack*: JsonNode
    partnerDist*: float
    hasPartnerDist*: bool

proc isPos*(node: JsonNode): bool =
  node != nil and node.kind == JArray and node.len == 2 and
    node[0].kind in {JInt, JFloat} and node[1].kind in {JInt, JFloat}

proc toPos*(node: JsonNode): Pos =
  (node[0].getFloat, node[1].getFloat)

proc dist*(a, b: Pos): float =
  hypot(a.x - b.x, a.y - b.y)

proc isNumber(node: JsonNode): bool =
  node != nil and node.kind in {JInt, JFloat}

# ---- scalar cleaning ------------------------------------------------------

proc clampNumber(value: JsonNode, spec: ParamSpec): JsonNode =
  if not value.isNumber:
    return nil
  let number = max(spec.min, min(spec.max, value.getFloat))
  if spec.kind == pkInt:
    %int(round(number))
  else:
    %number

proc seatRef(text: string): string =
  ## "seat:<N>" for a legal reference, else "".
  if not text.startsWith("seat:"):
    return ""
  let digits = text[5 .. ^1]
  if digits.len == 0 or not digits.allCharsInSet({'0'..'9'}) or digits.len > 3:
    return ""
  let number = parseInt(digits)
  if number > MaxSeat:
    return ""
  "seat:" & $number

proc cleanPartners(value: JsonNode): JsonNode =
  if value == nil or value.kind != JArray:
    return nil
  var seats: seq[string]
  for item in value:
    var text = ""
    if item.kind == JInt:
      text = "seat:" & $item.getInt
    elif item.kind == JString:
      text = item.getStr
    else:
      continue
    if text.startsWith("duo:"):
      continue
    let seatText = seatRef(text)
    if seatText.len > 0 and seatText notin seats:
      seats.add(seatText)
  # A "set" param sorts by its canonical encoding ("seat:10" < "seat:2").
  seats.sort()
  if seats.len == 0:
    return nil
  if seats.len > 8:
    seats.setLen(8)
  result = newJArray()
  for seat in seats:
    result.add(%seat)

proc cleanSeatRef(value: JsonNode): JsonNode =
  var text = ""
  if value.kind == JInt:
    text = "seat:" & $value.getInt
  elif value.kind == JString:
    text = value.getStr
  let seatText = seatRef(text)
  if seatText.len == 0: nil else: %seatText

proc cleanIntPair(value: JsonNode, spec: ParamSpec): JsonNode =
  if value.kind != JArray or value.len != 2:
    return nil
  var items: seq[int]
  for item in value:
    if not item.isNumber:
      return nil
    items.add(int(round(max(spec.min, min(spec.max, item.getFloat)))))
  %[min(items[0], items[1]), max(items[0], items[1])]

proc cleanUnion(value: JsonNode, spec: ParamSpec): JsonNode =
  if value.kind != JObject or value.len != 1:
    return nil
  for key, raw in value:
    for armSpec in spec.arms:
      if armSpec.name == key:
        if not raw.isNumber:
          return nil
        let number = int(round(max(float(armSpec.min),
          min(float(armSpec.max), raw.getFloat))))
        return %*{key: number}
  nil

proc cleanEnumList(value: JsonNode, spec: ParamSpec): JsonNode =
  if value.kind != JArray:
    return nil
  var seen: seq[string]
  for item in value:
    if item.kind == JString and item.getStr in spec.options and
        item.getStr notin seen:
      seen.add(item.getStr)
  if seen.len > spec.maxItems:
    seen.setLen(spec.maxItems)
  if seen.len == 0:
    return nil
  result = newJArray()
  for item in seen:
    result.add(%item)

proc cleanParams*(playName: string, params: JsonNode): JsonNode =
  ## Cleans one entry's params against the manifest; nil drops the entry
  ## (a required param did not survive).
  let play = Plays[findPlay(playName)]
  result = newJObject()
  if params != nil and params.kind == JObject:
    for key, value in params:
      let index = play.findParam(key)
      if index < 0:
        continue
      let spec = play.params[index]
      var cleaned: JsonNode = nil
      case spec.kind
      of pkInt, pkFloat: cleaned = clampNumber(value, spec)
      of pkBool: cleaned = (if value.kind == JBool: value else: nil)
      of pkEnum:
        cleaned = (if value.kind == JString and value.getStr in spec.options:
          value else: nil)
      of pkSeatSet: cleaned = cleanPartners(value)
      of pkSeatRef: cleaned = cleanSeatRef(value)
      of pkIntPair: cleaned = cleanIntPair(value, spec)
      of pkUnion: cleaned = cleanUnion(value, spec)
      of pkEnumList: cleaned = cleanEnumList(value, spec)
      if cleaned != nil:
        result[key] = cleaned
  for spec in play.params:
    if spec.required and not result.hasKey(spec.key):
      return nil

proc cleanEntryId(raw: JsonNode, playName: string, index: int,
                  seen: var seq[string]): string =
  var candidate = ""
  if raw != nil and raw.kind == JString:
    for ch in raw.getStr:
      if ch in EntryIdChars:
        candidate.add(ch)
      if candidate.len >= 32:
        break
  if candidate.len == 0:
    candidate = playName & "_" & $index
  while candidate in seen:
    candidate.add('x')
  seen.add(candidate)
  candidate

# ---- build_call -----------------------------------------------------------

proc entriesOf(decision: JsonNode): JsonNode =
  ## decision.call.entries (or .plays), else an empty array.
  if decision != nil and decision.kind == JObject and decision.hasKey("call") and
      decision["call"].kind == JObject:
    let call = decision["call"]
    for key in ["entries", "plays"]:
      if call.hasKey(key) and call[key].kind == JArray and call[key].len > 0:
        return call[key]
  newJArray()

proc buildCall*(decision: JsonNode, available: seq[string]):
    tuple[payload: string, entries: JsonNode] =
  ## Repairs a model reply into a canonical ladder call over the BAKED plays:
  ## unusable entries are dropped, and if nothing survives a bare controller
  ## stands in so the seat still declares something.
  var entries = newJArray()
  var seen: seq[string]
  var overlays = 0
  let rawEntries = entriesOf(decision)
  for index in 0 ..< rawEntries.len:
    let raw = rawEntries[index]
    if raw.kind != JObject:
      continue
    let playName = raw{"play"}.getStr("")
    if playName notin available:
      continue
    let isOverlay = playClass(playName) == pcOverlay
    if isOverlay and overlays >= MaxActiveOverlays:
      continue
    let params = cleanParams(playName, raw{"params"})
    if params == nil:
      continue
    if isOverlay:
      inc overlays
    var entry = %*{"play": playName,
      "entry_id": cleanEntryId(raw{"entry_id"}, playName, index, seen)}
    if params.len > 0:
      entry["params"] = params
    # `when` is deliberately NOT forwarded: the harness gates rungs itself.
    entries.add(entry)
    if entries.len >= MaxLadderEntries:
      break
  if entries.len == 0:
    var fallback = available[0]
    for name in available:
      if playClass(name) == pcController:
        fallback = name
        break
    entries.add(%*{"play": fallback, "entry_id": "ride"})
  let payload = canonicalJson(%*{"plays": entries})
  if payload.len > MaxCallBytes:
    raise newException(ValueError, "call is " & $payload.len &
      " bytes; cap is " & $MaxCallBytes)
  (payload, entries)

# ---- view facts and gates -------------------------------------------------

proc maxHp(view: JsonNode): float =
  let me = view{"self"}
  if me != nil and me{"hp"} != nil and me{"hp"}.kind == JInt and
      me{"hp_frac"}.isNumber and me{"hp_frac"}.getFloat > 0:
    return max(1.0, float(me{"hp"}.getInt) / me{"hp_frac"}.getFloat)
  MaxHpFallback

proc viewFacts*(view, context: JsonNode, killFeed: seq[JsonNode]): ViewFacts =
  ## The handful of facts the gates read, computed once per evaluation.
  result.partner = -1
  result.maxHp = maxHp(view)
  let me = if view != nil: view{"self"} else: nil
  if me != nil and isPos(me{"pos"}):
    result.hasPos = true
    result.pos = toPos(me{"pos"})
  if me != nil and me{"hp_frac"}.isNumber:
    result.hasHpFrac = true
    result.hpFrac = me{"hp_frac"}.getFloat
  let tick = if view != nil: view{"tick"}.getInt(0) else: 0
  let selfNode = if context != nil: context{"self"} else: nil
  let mySeat = if selfNode != nil: selfNode{"seat"}.getInt(-1) else: -1
  let myTeam = if selfNode != nil: selfNode{"team"}.getStr("") else: ""
  if selfNode != nil and selfNode{"duo_partner"} != nil and
      selfNode{"duo_partner"}.kind == JInt:
    result.partner = selfNode{"duo_partner"}.getInt
  if view != nil and view{"tracks"} != nil and view{"tracks"}.kind == JArray:
    for track in view{"tracks"}:
      if track.kind != JObject or not isPos(track{"pos"}):
        continue
      let seat = track{"seat"}.getInt(-2)
      if result.partner >= 0 and seat == result.partner:
        result.partnerTrack = track
        continue
      if seat == mySeat or (myTeam.len > 0 and track{"team"}.getStr("") == myTeam):
        continue
      let age = if track{"fresh_tick"} != nil and track{"fresh_tick"}.kind == JInt:
        tick - track{"fresh_tick"}.getInt else: 0
      if age <= TrackFreshTicks:
        result.enemies.add(track)
  if view != nil and view{"items"} != nil and view{"items"}.kind == JArray:
    for item in view{"items"}:
      if item.kind == JObject and item{"present"}.getBool(true) and isPos(item{"pos"}):
        result.items.add(item)
  if result.partner >= 0:
    for kill in killFeed:
      if kill{"victim_seat"}.getInt(-2) == result.partner:
        result.partnerDead = true
  if result.hasPos and result.enemies.len > 0:
    result.hasNearestEnemy = true
    result.nearestEnemy = Inf
    for track in result.enemies:
      result.nearestEnemy = min(result.nearestEnemy,
        dist(result.pos, toPos(track{"pos"})))
  if result.hasPos and result.partnerTrack != nil:
    result.hasPartnerDist = true
    result.partnerDist = dist(result.pos, toPos(result.partnerTrack{"pos"}))

proc itemWithin(facts: ViewFacts, maxPx: float, kinds: seq[string] = @[],
                exclude: seq[string] = @[]): bool =
  if not facts.hasPos:
    return false
  for item in facts.items:
    let kind = item{"kind"}.getStr("")
    if kinds.len > 0 and kind notin kinds:
      continue
    if kind in exclude:
      continue
    if dist(facts.pos, toPos(item{"pos"})) <= maxPx:
      return true
  false

proc paramOr(entry: JsonNode, key: string, default: JsonNode): JsonNode =
  let params = entry{"params"}
  if params != nil and params.kind == JObject and params.hasKey(key):
    params[key]
  else:
    default

proc gateOpen*(entry: JsonNode, facts: ViewFacts): bool =
  ## Should this controller be on the ladder right now?
  let playName = entry{"play"}.getStr("")
  case playName
  of "supply_run":
    let hpBelow = entry.paramOr("whenHpBelow", paramDefault("supply_run", "whenHpBelow")).getFloat
    let detour = entry.paramOr("detourMax", paramDefault("supply_run", "detourMax")).getFloat
    let wounded = facts.hasHpFrac and facts.hpFrac * facts.maxHp < hpBelow
    wounded and facts.itemWithin(detour, kinds = @["medkit"])
  of "loot":
    let detour = entry.paramOr("detourMax", paramDefault("loot", "detourMax")).getFloat
    let medkits = entry.paramOr("medkits", %false).getBool(false)
    let exclude = if medkits: @[] else: @["medkit"]
    (not facts.hasNearestEnemy or facts.nearestEnemy > LootClearPx) and
      facts.itemWithin(detour, exclude = exclude)
  of "bodyguard":
    let leash = entry.paramOr("leash", paramDefault("bodyguard", "leash"))
    var leashMax = 220.0
    if leash != nil and leash.kind == JArray and leash.len == 2:
      leashMax = leash[1].getFloat
    if facts.partner < 0 or facts.partnerDead or facts.partnerTrack == nil:
      return false
    facts.hasPartnerDist and facts.partnerDist > leashMax
  of "jackal":
    facts.enemies.len > 0
  of "crossfire":
    facts.partner >= 0 and not facts.partnerDead and
      facts.partnerTrack != nil and facts.enemies.len > 0
  else:
    true

proc copyEntry(entry: JsonNode): JsonNode =
  result = copy(entry)
  if result.hasKey("when"):
    result.delete("when")

proc layerLadder*(entries: JsonNode, view, context: JsonNode,
                  killFeed: seq[JsonNode], basePlay: string): JsonNode =
  ## The ladder to actually send: overlays first, then the gated controllers
  ## whose gate is open right now, then the always-on base. basePlay "" means
  ## no base controller (the engine default drives).
  let facts = viewFacts(view, context, killFeed)
  var overlays = newJArray()
  var gated = newJArray()
  var base: seq[JsonNode]
  for raw in entries:
    let playName = raw{"play"}.getStr("")
    if not isKnownPlay(playName):
      continue
    let entry = copyEntry(raw)
    if playClass(playName) == pcOverlay:
      overlays.add(entry)
    elif playName == basePlay:
      base.add(entry)
    elif playName in GatedPlays:
      if gateOpen(entry, facts):
        gated.add(entry)
    elif basePlay.len == 0:
      continue
    else:
      base.add(entry)
  if basePlay.len > 0 and isKnownPlay(basePlay):
    var present = false
    for entry in base:
      if entry{"play"}.getStr("") == basePlay:
        present = true
    if not present:
      var defaults = newJObject()
      for spec in Plays[findPlay(basePlay)].params:
        if spec.hasDefault:
          defaults[spec.key] = spec.default
      base.add(%*{"play": basePlay, "entry_id": "base_" & basePlay,
        "params": defaults})
  # The persona's base play outranks any other unguarded controller.
  base.sort(proc(a, b: JsonNode): int =
    cmp(int(a{"play"}.getStr("") != basePlay), int(b{"play"}.getStr("") != basePlay)))
  if basePlay.len == 0 and overlays.len == 0 and gated.len == 0:
    overlays.add(%*{"play": "target_law", "entry_id": "noop"})
  result = newJArray()
  for entry in overlays: result.add(entry)
  for entry in gated: result.add(entry)
  for entry in base: result.add(entry)

# ---- clones ---------------------------------------------------------------

proc baseName*(name: string): string =
  ## 'James Botts (2)' -> 'James Botts': the roster de-duplicates one
  ## entrant's seats with a ' (N)' suffix.
  let stripped = name.strip(leading = false)
  if stripped.endsWith(")") and " (" in stripped:
    let at = stripped.rfind(" (")
    let tail = stripped[at + 2 ..< stripped.len - 1]
    if tail.len > 0 and tail.allCharsInSet({'0'..'9'}):
      return stripped[0 ..< at]
  stripped

proc seatName*(context: JsonNode, seat: int): string =
  ## The display name the PlayContext roster carries for a seat, or "".
  if context == nil or context{"roster"} == nil:
    return ""
  for row in context{"roster"}:
    if row.kind == JObject and row{"seat"}.getInt(-1) == seat:
      return row{"name"}.getStr("")

proc cloneSeats*(context: JsonNode): seq[int] =
  ## The other seats this same entrant is driving (to the body a clone is
  ## just an enemy, and entrants were shooting their own score).
  let selfNode = if context != nil: context{"self"} else: nil
  if selfNode == nil:
    return
  let mySeat = selfNode{"seat"}.getInt(-1)
  let mine = baseName(seatName(context, mySeat))
  if mine.len == 0:
    return
  for row in context{"roster"}:
    if row.kind != JObject or row{"seat"}.getInt(-1) == mySeat:
      continue
    if baseName(row{"name"}.getStr("")) == mine and row{"seat"} != nil and
        row{"seat"}.kind == JInt:
      result.add(row{"seat"}.getInt)
  result.sort()

proc findEntry(entries: JsonNode, playName: string): JsonNode =
  for entry in entries:
    if entry{"play"}.getStr("") == playName:
      return entry
  nil

proc stringList(params: JsonNode, key: string): seq[string] =
  if params.hasKey(key) and params[key].kind == JArray:
    for item in params[key]:
      if item.kind == JString:
        result.add(item.getStr)

proc allyClones*(entries: JsonNode, context: JsonNode): JsonNode =
  ## Never shoot yourself: pact with every clone seat and keep them on
  ## target_law's never-list. Idempotent.
  result = entries
  let clones = cloneSeats(context)
  if clones.len == 0:
    return
  var refs: seq[string]
  for seat in clones:
    refs.add("seat:" & $seat)
  var pact = findEntry(entries, "pact")
  if pact == nil:
    pact = %*{"play": "pact", "entry_id": "clones", "params": {}}
    result = newJArray()
    result.add(pact)
    for entry in entries:
      result.add(entry)
  if not pact.hasKey("params") or pact["params"].kind != JObject:
    pact["params"] = newJObject()
  var partners = stringList(pact["params"], "partners")
  for r in refs:
    if r notin partners:
      partners.add(r)
  pact["params"]["partners"] = %partners
  var law = findEntry(result, "target_law")
  if law == nil:
    law = %*{"play": "target_law", "entry_id": "no_clone_fire", "params": {}}
    result.add(law)
  if not law.hasKey("params") or law["params"].kind != JObject:
    law["params"] = newJObject()
  var never = stringList(law["params"], "never")
  for r in refs:
    if r notin never:
      never.add(r)
  law["params"]["never"] = %never

proc entriesOfPayload*(payload: string): JsonNode =
  try:
    let node = parseJson(payload)
    if node{"plays"} != nil and node{"plays"}.kind == JArray:
      return node{"plays"}
  except CatchableError:
    discard
  newJArray()

proc entryIds*(entries: JsonNode): seq[string] =
  for entry in entries:
    result.add(entry{"entry_id"}.getStr("?"))
