## The three starter personas (ports of policies/starters/*/policy.py): the
## prompt, the persona notes, the canned turns, the live-loop schedule, and
## the adjust/extra-chat hooks that make each seat behave unlike the others.
## The system prompts are the starters' own files, read at compile time.

import std/json

type
  AdjustHook* = proc(entries: JsonNode, context, view: JsonNode): JsonNode {.nimcall.}
  ChatHook* = proc(context: JsonNode, turn: int): string {.nimcall.}

  Persona* = object
    name*: string
    promptIntro*: string
    playNotes*: seq[tuple[play, note: string]]
    cannedTurns*: seq[JsonNode]
    recallSeconds*: float
    periodicSeconds*: float      ## 0 = three times recallSeconds
    maxCalls*: int
    basePlay*: string            ## "" = no base controller
    spawnPhaseTicks*: int
    includeKillFeed*: bool
    partnerFocus*: bool
    adjustEntries*: AdjustHook
    extraChat*: ChatHook

proc params(entry: JsonNode): JsonNode =
  if not entry.hasKey("params") or entry["params"].kind != JObject:
    entry["params"] = newJObject()
  entry["params"]

proc has(entries: JsonNode, playName: string): bool =
  for entry in entries:
    if entry{"play"}.getStr("") == playName:
      return true
  false

proc first(entries: JsonNode, playName: string): JsonNode =
  for entry in entries:
    if entry{"play"}.getStr("") == playName:
      return entry
  nil

proc numberOr(node: JsonNode, default: float): float =
  if node != nil and node.kind in {JInt, JFloat}: node.getFloat else: default

proc stringList(params: JsonNode, key: string): seq[string] =
  if params.hasKey(key) and params[key].kind == JArray:
    for item in params[key]:
      if item.kind == JString:
        result.add(item.getStr)

proc partnerOf(context: JsonNode): int =
  let selfNode = if context != nil: context{"self"} else: nil
  if selfNode != nil and selfNode{"duo_partner"} != nil and
      selfNode{"duo_partner"}.kind == JInt:
    selfNode{"duo_partner"}.getInt
  else:
    -1

# ---- cautious -------------------------------------------------------------

const
  CautiousMinMargin = 280
  CautiousMinEnterLead = 220
  CautiousMinCoverBias = 0.8

proc cautiousAdjust(entries: JsonNode, context, view: JsonNode): JsonNode =
  result = entries
  for entry in entries:
    let p = entry.params
    case entry{"play"}.getStr("")
    of "edge_ride":
      if not p.hasKey("margin"): p["margin"] = %340
      if not p.hasKey("enterLead"): p["enterLead"] = %280
      if not p.hasKey("coverBias"): p["coverBias"] = %0.9
      p["margin"] = %max(int(p["margin"].numberOr(340)), CautiousMinMargin)
      p["enterLead"] = %max(int(p["enterLead"].numberOr(280)), CautiousMinEnterLead)
      p["coverBias"] = %max(p["coverBias"].numberOr(0.9), CautiousMinCoverBias)
    of "pact":
      p["onBetrayal"] = %"disengage"
    of "target_law":
      let trigger = p{"holdTrigger"}
      if trigger != nil and trigger.kind == JObject and trigger.hasKey("aliveTeams"):
        trigger["aliveTeams"] = %max(int(trigger["aliveTeams"].numberOr(7)), 7)
      elif trigger != nil and trigger.kind == JObject and trigger.hasKey("zonePhase"):
        trigger["zonePhase"] = %min(int(trigger["zonePhase"].numberOr(1)), 1)
      elif trigger == nil or trigger.kind != JObject:
        p["holdTrigger"] = %*{"zonePhase": 1}
    of "supply_run":
      if not p.hasKey("detourMax"): p["detourMax"] = %900
      p["whenHpBelow"] = %max(int(p{"whenHpBelow"}.numberOr(4)), 4)
      p["contested"] = %"avoid"
    of "loot":
      p["contested"] = %"avoid"
      p["detourMax"] = %min(int(p{"detourMax"}.numberOr(300)), 300)
    else:
      discard
  if not entries.has("loot"):
    entries.add(%*{"play": "loot", "entry_id": "loot",
      "params": {"detourMax": 300, "contested": "avoid"}})

const
  CautiousPrompt = staticRead("../../starters/cautious/system_prompt.md")
  AggressivePrompt = staticRead("../../starters/aggressive/system_prompt.md")
  CollaborativePrompt = staticRead("../../starters/collaborative/system_prompt.md")

let CautiousPersona* = Persona(
  name: "cautious",
  promptIntro: CautiousPrompt,
  playNotes: @[
    ("loot", "loot: short, safe detours only -- a shield or a grenade within 300 px while nobody is tracked; the harness keeps it off the ladder the moment an enemy appears."),
    ("edge_ride", "edge_ride is your whole game: margin 280 or wider, enterLead 220 or more, coverBias 0.8+. Rotate early, arrive first, sit in cover."),
    ("pact", "accept a pact when it reduces threats; onBetrayal is always disengage."),
    ("supply_run", "supply_run rides above your edge_ride in every call once you have taken ANY damage: whenHpBelow 4+ (hp is a small absolute number -- a full seat is only a few units), wide detourMax, contested always avoid."),
    ("bodyguard", "bodyguard only for a partner already in a pact, and with a wide leash -- never interpose."),
    ("target_law", "target_law: always carry a holdTrigger, but one that actually releases while you are alive -- {\"zonePhase\": 1} releases at the drop (the zone reports phase 1 from the first tick) -- carry it, but do not expect a hold; an aliveTeams trigger below 7 never fires before you die. A released hold NEVER re-arms.")],
  cannedTurns: @[
    %*{"chat": "No heroes over here. Riding the wide line, shooting only what comes to me. Good luck all.",
       "call": {"entries": [
         {"play": "edge_ride", "entry_id": "shelter",
          "params": {"margin": 420, "enterLead": 320, "coverBias": 1.0}},
         {"play": "target_law", "entry_id": "discipline",
          "params": {"holdTrigger": {"zonePhase": 1}}}]}},
    %*{"chat": "Holding my corridor. If I take a scratch I am going straight for a medkit.",
       "call": {"entries": [
         {"play": "supply_run", "entry_id": "medkit",
          "params": {"whenHpBelow": 5, "detourMax": 900, "contested": "avoid"}},
         {"play": "edge_ride", "entry_id": "shelter",
          "params": {"margin": 340, "enterLead": 300, "coverBias": 1.0}}]}}],
  recallSeconds: 15.0,
  maxCalls: 4,
  basePlay: "edge_ride",
  spawnPhaseTicks: 150,
  adjustEntries: cautiousAdjust)

# ---- aggressive -----------------------------------------------------------

const
  AggressiveMaxMargin = 260
  AggressiveMaxEnterLead = 200
  AggressiveMaxCoverBias = 0.8

proc aggressiveAdjust(entries: JsonNode, context, view: JsonNode): JsonNode =
  result = entries
  for entry in entries:
    let p = entry.params
    case entry{"play"}.getStr("")
    of "edge_ride":
      p["margin"] = %min(int(p{"margin"}.numberOr(180)), AggressiveMaxMargin)
      p["enterLead"] = %min(int(p{"enterLead"}.numberOr(120)), AggressiveMaxEnterLead)
      p["coverBias"] = %min(p{"coverBias"}.numberOr(0.5), AggressiveMaxCoverBias)
    of "pact":
      p["onBetrayal"] = %"returnFire"
      p["protect"] = %false
    of "supply_run":
      p["contested"] = %"race"
    of "loot":
      p["contested"] = %"race"
    else:
      discard
  if not entries.has("loot"):
    entries.add(%*{"play": "loot", "entry_id": "loot",
      "params": {"detourMax": 500, "contested": "race"}})

let AggressivePersona* = Persona(
  name: "aggressive",
  promptIntro: AggressivePrompt,
  playNotes: @[
    ("loot", "loot: grenades and spray cans are your tools -- race for them when nobody is tracked; the harness gates it."),
    ("edge_ride", "edge_ride is your hunting lane: margin 140-260, enterLead up to 200, coverBias up to 0.8. The edge is where the rotations funnel -- meet them there, from cover."),
    ("pact", "pact only when it buys you a fight you would lose alone; never protect, always returnFire on betrayal."),
    ("supply_run", "supply_run only when a kit is on your path or contested -- and a contested kit you RACE, never avoid. Keep whenHpBelow low; healing is for after the fight."),
    ("bodyguard", "bodyguard is not your play -- you are nobody's shield. Skip it."),
    ("jackal", "jackal is your signature: wide earshot, join after the first kill, exit with one or two kills banked. Be honest with yourself: the kill feed only tells you a fight HAPPENED -- you can only move on fights your own fog tracks can see."),
    ("crossfire", "crossfire: tight spacing band, wide angles -- concentrate the opening volley. Your partner is only where your own tracks last saw them."),
    ("target_law", "target_law: prefer weakened and isolated targets; keep the never-list empty unless a pact demands it, and NEVER set a holdTrigger -- you fire at will.")],
  cannedTurns: @[
    %*{"chat": "Dropping hot. First blood inside the minute -- watch the feed.",
       "call": {"entries": [
         {"play": "edge_ride", "entry_id": "hunt",
          "params": {"margin": 200, "enterLead": 140, "coverBias": 0.5}}]}},
    %*{"chat": "Feed is ticking. Pushing the next fight -- the wounded first.",
       "call": {"entries": [
         {"play": "edge_ride", "entry_id": "hunt",
          "params": {"margin": 170, "enterLead": 110, "coverBias": 0.45}},
         {"play": "target_law", "entry_id": "law",
          "params": {"prefer": ["weakened", "isolated"]}}]}},
    %*{"chat": "Somebody just died out there. Going shopping.",
       "call": {"entries": [
         {"play": "jackal", "entry_id": "scavenge",
          "params": {"earshot": 900, "joinWhen": "afterKill", "exitAfter": {"kills": 2}}},
         {"play": "edge_ride", "entry_id": "hunt",
          "params": {"margin": 140, "enterLead": 80, "coverBias": 0.4}}]}}],
  recallSeconds: 6.0,
  maxCalls: 8,
  basePlay: "edge_ride",
  spawnPhaseTicks: 340,
  includeKillFeed: true,
  adjustEntries: aggressiveAdjust)

# ---- collaborative --------------------------------------------------------

proc collaborativeAdjust(entries: JsonNode, context, view: JsonNode): JsonNode =
  result = entries
  let partner = partnerOf(context)
  var pact = entries.first("pact")
  if pact == nil:
    pact = %*{"play": "pact", "entry_id": "duo_pact", "params": {}}
    result = newJArray()
    result.add(pact)
    for entry in entries:
      result.add(entry)
  let pp = pact.params
  var partners = stringList(pp, "partners")
  if partner >= 0 and ("seat:" & $partner) notin partners:
    partners.add("seat:" & $partner)
  pp["partners"] = %partners
  pp["protect"] = %true
  if not pp.hasKey("onBetrayal"): pp["onBetrayal"] = %"disengage"
  for entry in result:
    case entry{"play"}.getStr("")
    of "bodyguard":
      let guard = entry.params
      guard["interpose"] = %true
      if partner >= 0:
        guard["ward"] = %("seat:" & $partner)
    of "target_law":
      let law = entry.params
      var never = stringList(law, "never")
      if partner >= 0 and ("seat:" & $partner) notin never:
        never.add("seat:" & $partner)
      if never.len > 0:
        law["never"] = %never
    else:
      discard
  if not result.has("edge_ride") and not result.has("bodyguard"):
    result.add(%*{"play": "edge_ride", "entry_id": "together",
      "params": {"margin": 260, "enterLead": 180, "coverBias": 0.85}})
  if not result.has("loot"):
    result.add(%*{"play": "loot", "entry_id": "loot",
      "params": {"detourMax": 400, "contested": "avoid"}})

proc collaborativeChat(context: JsonNode, turn: int): string =
  let partner = partnerOf(context)
  if partner < 0:
    return ""
  if turn == 1:
    "seat " & $partner & ": pact is live and protect is on. Hold 150px off my shoulder, stay out of my firing line, and we rotate together."
  else:
    "seat " & $partner & ": rotating with the zone edge -- stay on my flank, shout if you take fire and I will peel."

let CollaborativePersona* = Persona(
  name: "collaborative",
  promptIntro: CollaborativePrompt,
  playNotes: @[
    ("loot", "loot: kit up while the duo is unbothered; never fight over a pickup. The harness gates it."),
    ("pact", "pact is your first entry in EVERY call: your duo partner in partners, protect true, disengage on betrayal."),
    ("edge_ride", "edge_ride steady and readable (margin ~260) so your partner can hold formation on you."),
    ("bodyguard", "bodyguard is how you carry the pact mid-match: ward your partner (it defaults to them), tight leash like [60, 180], interpose true, peelHp 3 so you peel attackers off them early (hp is a small absolute number)."),
    ("crossfire", "crossfire is the duo's teeth: keep the spacing band so both guns bear without friendly-fire geometry. It sees your partner only through your own fog tracks, so stay where you can see each other."),
    ("supply_run", "supply_run for your PARTNER's health as much as yours; race the medkit they cannot reach."),
    ("target_law", "target_law's never-list always carries your partner (the harness guarantees it); prefer \"revenge\" so their attacker becomes your target.")],
  cannedTurns: @[
    %*{"chat": "Partner, on me -- pact up, protect on. We rotate as one.",
       "call": {"entries": [
         {"play": "pact", "entry_id": "duo_pact",
          "params": {"protect": true, "onBetrayal": "disengage"}},
         {"play": "target_law", "entry_id": "law", "params": {"prefer": ["revenge"]}},
         {"play": "edge_ride", "entry_id": "together",
          "params": {"margin": 260, "enterLead": 180, "coverBias": 0.85}}]}},
    %*{"chat": "Tight now -- I am your shield, you are my gun.",
       "call": {"entries": [
         {"play": "pact", "entry_id": "duo_pact",
          "params": {"protect": true, "onBetrayal": "disengage"}},
         {"play": "bodyguard", "entry_id": "guard",
          "params": {"leash": [60, 180], "interpose": true, "peelHp": 3}},
         {"play": "crossfire", "entry_id": "cross",
          "params": {"spacing": [100, 260], "minAngle": 40}}]}}],
  recallSeconds: 10.0,
  maxCalls: 6,
  basePlay: "edge_ride",
  spawnPhaseTicks: 150,
  partnerFocus: true,
  adjustEntries: collaborativeAdjust,
  extraChat: collaborativeChat)

proc personaNamed*(name: string): Persona =
  case name
  of "aggressive": AggressivePersona
  of "collaborative": CollaborativePersona
  else: CautiousPersona
