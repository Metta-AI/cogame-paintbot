## The plays manifest: the single source of truth for every play a starter
## can bake and speak about (port of policies/starters/common/plays.py).
## The param specs drive repair, the briefs build the prompt, and the baked
## playbook must be covered here or the build refuses (starter.nim).

import std/[json, strutils]

type
  ParamKind* = enum
    pkInt, pkFloat, pkBool, pkEnum, pkSeatSet, pkSeatRef, pkIntPair, pkUnion,
    pkEnumList

  UnionArm* = object
    name*: string
    min*: int
    max*: int          ## high(int32) when unbounded
    hasMax*: bool

  ParamSpec* = object
    key*: string
    kind*: ParamKind
    min*: float
    max*: float
    hasDefault*: bool
    default*: JsonNode
    options*: seq[string]    ## enum / enum_list
    arms*: seq[UnionArm]     ## union
    minItems*: int
    maxItems*: int
    required*: bool

  PlayClass* = enum
    pcController = "controller", pcOverlay = "overlay"

  PlaySpec* = object
    name*: string
    class*: PlayClass
    params*: seq[ParamSpec]
    brief*: string

proc intParam(key: string, min, max, default: int, required = false): ParamSpec =
  ParamSpec(key: key, kind: pkInt, min: float(min), max: float(max),
    hasDefault: true, default: %default, required: required)

proc floatParam(key: string, min, max, default: float): ParamSpec =
  ParamSpec(key: key, kind: pkFloat, min: min, max: max, hasDefault: true,
    default: %default)

proc boolParam(key: string, default: bool): ParamSpec =
  ParamSpec(key: key, kind: pkBool, hasDefault: true, default: %default)

proc enumParam(key: string, options: openArray[string], default: string): ParamSpec =
  ParamSpec(key: key, kind: pkEnum, options: @options, hasDefault: true,
    default: %default)

proc seatSetParam(key: string, minItems, maxItems: int, required: bool): ParamSpec =
  ParamSpec(key: key, kind: pkSeatSet, minItems: minItems, maxItems: maxItems,
    required: required)

proc seatRefParam(key: string): ParamSpec =
  ParamSpec(key: key, kind: pkSeatRef)

proc intPairParam(key: string, min, max, lo, hi: int): ParamSpec =
  ParamSpec(key: key, kind: pkIntPair, min: float(min), max: float(max),
    hasDefault: true, default: %[lo, hi])

proc unionParam(key: string, arms: openArray[UnionArm], default: JsonNode): ParamSpec =
  ParamSpec(key: key, kind: pkUnion, arms: @arms, hasDefault: default != nil,
    default: default)

proc arm(name: string, min, max: int): UnionArm =
  UnionArm(name: name, min: min, max: max, hasMax: true)

proc openArm(name: string, min: int): UnionArm =
  UnionArm(name: name, min: min, max: high(int32), hasMax: false)

proc enumListParam(key: string, options: openArray[string], maxItems: int): ParamSpec =
  ParamSpec(key: key, kind: pkEnumList, options: @options, maxItems: maxItems)

const
  EdgeRideBrief = "\"edge_ride\" (class: controller). Rides the inside margin of the safe zone, biased through cover; enters the next ring as late as safety allows. Params:\n     - margin: integer 40..600, default 220. Distance inside the zone edge to sit at. Smaller = tighter, more exposed edge play.\n     - enterLead: integer 0..600, default 120. How early to start rotating before the zone shrinks. Larger = earlier, safer rotations.\n     - coverBias: number 0.0..1.0, default 0.8. Higher = detour further to stay in cover."
  PactBrief = "\"pact\" (class: overlay). A negotiated alliance: never target the partners, dissolve at the endgame. Params:\n     - partners: REQUIRED list of 1..8 seat references, each of the exact form \"seat:<N>\" with N from 0 to 31. No other form is legal.\n     - protect: boolean, default false. Also body-block and peel for partners.\n     - onBetrayal: one of \"returnFire\" or \"disengage\", default \"returnFire\". What to do if a partner shoots us first."
  SupplyRunBrief = "\"supply_run\" (class: controller). Detours to reachable medkits when wounded; avoids or races contested pickups. It only knows items currently in view (no memory). Params:\n     - whenHpBelow: integer 0..64, default 3. ABSOLUTE hp units (hp values are small integers, NOT a percentage or fraction): run for a medkit when your hp drops below this.\n     - detourMax: integer 0..4096, default 500. Maximum detour in px to reach an item.\n     - contested: one of \"avoid\" or \"race\", default \"avoid\". What to do when someone else is also heading for the item."
  ScatterBrief = "\"scatter\" (class: controller). Gets off the spawn cluster: for the opening ticks it walks away from the nearest tracked enemy (toward the zone centre when nobody is tracked), then yields. The harness makes it the base rung for the first seconds of every match. Params:\n     - distance: integer 60..1200, default 320. How far to walk per leg.\n     - ticks: integer 24..2400, default 300. How long after the drop to keep scattering (24 ticks = 1 s)."
  LootBrief = "\"loot\" (class: controller). Fetches the nearest reachable pickup of any kind -- grenade, shield, spray can, barrier -- when it is safe to. The harness gates it so it only runs while no fresh enemy track is within 500 px and an item is within reach; otherwise your base play keeps driving. Params:\n     - detourMax: integer 0..4096, default 400. Maximum detour in px to reach an item.\n     - contested: one of \"avoid\" or \"race\", default \"avoid\". What to do when someone else is also heading for the item.\n     - medkits: boolean, default false. Also fetch medkits (normally supply_run's job)."
  BodyguardBrief = "\"bodyguard\" (class: controller). Ward-relative movement: hold a leash to the ward, interpose between ward and nearest threat, peel attackers off a wounded ward. Ward knowledge comes from fog tracks; if the ward's track is stale it holds at the last known position. Params:\n     - ward: one seat reference of the exact form \"seat:<N>\". Optional -- when omitted it defaults to your duo partner. No \"duo:<team>\" form.\n     - leash: [min, max] integers 0..4096 px with min <= max, default [80, 220]. The distance band to hold around the ward.\n     - interpose: boolean, default true. Step between the ward and the nearest threat.\n     - peelHp: integer 0..64, default 2. ABSOLUTE hp units: when the ward's hp is below this, engage their attacker."
  CrossfireBrief = "\"crossfire\" (class: controller). Keeps you and your duo partner inside a spacing band and off a shared firing axis, so both guns bear without friendly-fire geometry. It knows the partner only through YOUR OWN fog tracks (no live duo telemetry; a stale track means last-known position, never-seen means hold), and the shared target is the nearest enemy visible to YOU. Params:\n     - spacing: [min, max] integers 0..600 px, default [120, 320]. The distance band to hold around the partner.\n     - minAngle: integer 0..128 brads, default 32. Minimum angular separation of the two guns on the shared target."
  JackalBrief = "\"jackal\" (class: controller). Loiters at earshot of an active fight, joins only when it is cheap, and leaves with the profit. BE HONEST ABOUT WHAT IT SEES: the public kill feed only SIGNALS that a fight happened -- it carries no location, so the play navigates purely by your own fog tracks; \"bothWeakened\" fires only when 2+ enemies with known hp inside earshot are ALL weak; exit-kill counting uses your own team's kill-feed rows while engaged. Params:\n     - earshot: integer 100..1200 px, default 500. Loiter distance from the fight.\n     - joinWhen: \"afterKill\" or \"bothWeakened\", default \"afterKill\". When it is cheap enough to join.\n     - exitAfter: an object with EXACTLY ONE of \"kills\" (integer 1..4) or \"hpFloor\" (integer 0..3 absolute hp units), default {\"kills\": 1}. When to leave with the profit."
  TargetLawBrief = "\"target_law\" (class: overlay). The standing targeting filter under every other play: who never to shoot, who to prefer, and when to hold first fire. Params:\n     - never: list of 0..8 seat references (\"seat:<N>\"), default []. Do-not-shoot list.\n     - prefer: ordered list of up to 4 of \"weakened\", \"isolated\", \"revenge\", \"bounty\", default []. LIVE target scoring bias, applied engine-side.\n     - holdTrigger: optional object with EXACTLY ONE of \"aliveTeams\" (integer 2..16), \"zonePhase\" (integer 1..8), or \"tick\" (integer >= 0). Hold ALL fire until the condition; omit it to fire at will. THE HOLD IS A COMMITMENT: once released it stays released for the rest of your life -- a later re-call can change never/prefer but can never re-arm a released hold."

  LadderRules* = "A ladder is an ordered list of entries; the first non-overlay entry is the\ncontroller that drives the seat, and overlays modify it. At most 2 overlays.\n"

let Plays*: seq[PlaySpec] = @[
  PlaySpec(name: "edge_ride", class: pcController, brief: EdgeRideBrief, params: @[
    intParam("margin", 40, 600, 220),
    intParam("enterLead", 0, 600, 120),
    floatParam("coverBias", 0.0, 1.0, 0.8)]),
  PlaySpec(name: "pact", class: pcOverlay, brief: PactBrief, params: @[
    seatSetParam("partners", 1, 8, required = true),
    boolParam("protect", false),
    enumParam("onBetrayal", ["disengage", "returnFire"], "returnFire")]),
  PlaySpec(name: "supply_run", class: pcController, brief: SupplyRunBrief, params: @[
    intParam("whenHpBelow", 0, 64, 3),
    intParam("detourMax", 0, 4096, 500),
    enumParam("contested", ["avoid", "race"], "avoid")]),
  PlaySpec(name: "scatter", class: pcController, brief: ScatterBrief, params: @[
    intParam("distance", 60, 1200, 320),
    intParam("ticks", 24, 2400, 300)]),
  PlaySpec(name: "loot", class: pcController, brief: LootBrief, params: @[
    intParam("detourMax", 0, 4096, 400),
    enumParam("contested", ["avoid", "race"], "avoid"),
    boolParam("medkits", false)]),
  PlaySpec(name: "bodyguard", class: pcController, brief: BodyguardBrief, params: @[
    seatRefParam("ward"),
    intPairParam("leash", 0, 4096, 80, 220),
    boolParam("interpose", true),
    intParam("peelHp", 0, 64, 2)]),
  PlaySpec(name: "crossfire", class: pcController, brief: CrossfireBrief, params: @[
    intPairParam("spacing", 0, 600, 120, 320),
    intParam("minAngle", 0, 128, 32)]),
  PlaySpec(name: "jackal", class: pcController, brief: JackalBrief, params: @[
    intParam("earshot", 100, 1200, 500),
    enumParam("joinWhen", ["afterKill", "bothWeakened"], "afterKill"),
    unionParam("exitAfter", [arm("kills", 1, 4), arm("hpFloor", 0, 3)],
      %*{"kills": 1})]),
  PlaySpec(name: "target_law", class: pcOverlay, brief: TargetLawBrief, params: @[
    seatSetParam("never", 0, 8, required = false),
    enumListParam("prefer", ["bounty", "isolated", "revenge", "weakened"], 4),
    unionParam("holdTrigger", [arm("aliveTeams", 2, 16), arm("zonePhase", 1, 8),
      openArm("tick", 0)], nil)])]

proc findPlay*(name: string): int =
  ## Index into Plays, or -1.
  for index, play in Plays:
    if play.name == name:
      return index
  -1

proc isKnownPlay*(name: string): bool = findPlay(name) >= 0

proc playClass*(name: string): PlayClass =
  Plays[findPlay(name)].class

proc findParam*(play: PlaySpec, key: string): int =
  for index, spec in play.params:
    if spec.key == key:
      return index
  -1

proc paramDefault*(playName, key: string): JsonNode =
  ## The manifest default for one param (nil when it has none).
  let index = findPlay(playName)
  if index < 0:
    return nil
  let p = Plays[index].findParam(key)
  if p < 0 or not Plays[index].params[p].hasDefault:
    return nil
  Plays[index].params[p].default

proc playbookBrief*(available: seq[string]): string =
  ## The prompt section describing exactly the plays in the baked playbook.
  let count =
    case available.len
    of 1: "one play"
    of 2: "exactly two plays"
    else: "exactly " & $available.len & " plays"
  var lines = @["Your playbook has " & count & ", already uploaded to the server.", ""]
  for index, name in available:
    lines.add($(index + 1) & ". " & Plays[findPlay(name)].brief)
    lines.add("")
  lines.add(LadderRules)
  lines.join("\n")

proc formatRules*(available: seq[string]): string =
  ## The reply-format contract, with the legal play names inlined.
  var names: seq[string]
  for name in available:
    names.add("\"" & name & "\"")
  var controller = available[0]
  for name in available:
    if playClass(name) == pcController:
      controller = name
      break
  "Reply with a single JSON object and nothing else:\n\n" &
  "{\n  \"chat\": \"one short line of lobby chat, under 200 characters\",\n" &
  "  \"call\": {\n    \"entries\": [\n" &
  "      {\"play\": \"" & controller & "\", \"entry_id\": \"ride\", \"params\": {\"margin\": 240}}\n" &
  "    ]\n  }\n}\n\n" &
  "Rules: every \"play\" must be " & names.join(" or ") & ". Every \"entry_id\" must be\n" &
  "unique within the call and made of letters, digits, underscores or hyphens.\n" &
  "Only use parameters named above, within their stated ranges. Include at least\n" &
  "one entry. In \"chat\", address other players by the NAME the roster gives\n" &
  "them (they see yours); inside \"call\", a seat is always written seat:<N>.\n"
