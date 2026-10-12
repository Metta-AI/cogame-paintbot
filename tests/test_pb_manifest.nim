## The manifest contract for the deprecated paintball variant. The certifier
## validates every variant and the certification fixture against config_schema
## (additionalProperties: false) and rejects any results key the schema does
## not name, so these assertions still pin the archived variant's shape.
##
## CONCURRENCY: this suite's "the replay viewer is the STATIC bundle" test
## reads the manifest's declared bundle name ("static-replay-viewer"), not
## the directory's contents -- but still do not run it concurrently with a
## tools/build_replay_viewer.sh rebuild. That script `rm -rf`s the
## static-replay-viewer/ directory mid-run (see test_season2_replay_hud.nim,
## which does read the directory's contents and hits this window directly),
## and any assertion added here later against the bundle's actual contents
## would inherit the same phantom-failure risk.
import std/[json, strutils, unittest]
import pb_helpers

const
  ManifestPath = "coworld_manifest_paintbot.json"
  ArchivePath = "deprecated_variants_paintbot.json"
  Seats = 2
  EpisodeTimeoutSeconds = 1200

suite "paintbot manifest and deprecated variants":
  let manifest = parseJson(readFile(ManifestPath))
  let archive = parseJson(readFile(ArchivePath))
  let game = manifest["game"]

  test "the paintball variant exists, with 2 seats and both regimes":
    var found = false
    for variant in archive["variants"]:
      if variant["id"].getStr() != "paintball":
        continue
      found = true
      let cfg = variant["game_config"]
      check cfg["num_agents"].getInt() == Seats
      check cfg["loadout"].getStr() == "paintball"
      check cfg["floorPaint"].getBool()
      check cfg["paintBuff"].getBool()
      check cfg["hill"].getBool()
      check cfg["maxGames"].getInt() == 2
      check cfg["regimes"].len == 2
      check variant["description"].getStr().len > 0
    check found

  test "every declared player occupies a certification slot":
    ## The raid 0.1.2 `players_missing` scar: a manifest that declares players
    ## the certification fixture does not seat fails cert outright. This is
    ## exactly why the paintball baselines are uploaded policies, never
    ## manifest players.
    var declared: seq[string]
    for player in manifest["player"]:
      declared.add(player["id"].getStr())
    var seated: seq[string]
    for slot in manifest["certification"]["players"]:
      seated.add(slot["player_id"].getStr())
    for id in declared:
      check id in seated

  test "results_schema covers every key BOTH results documents write":
    let schema = game["results_schema"]
    check schema["additionalProperties"].getBool() == false
    var schemaKeys: seq[string]
    for key in schema["properties"].keys:
      schemaKeys.add(key)
    # The paintball (squad) document.
    var sim = newPaintballSim()
    var half: array[Team, int]
    half[Red] = 600
    half[Blue] = 300
    sim.gameHill = @[half]
    sim.gameRegimes = @[regimeResident]
    for key in parseJson(sim.playerResultsJson()).keys:
      check key in schemaKeys
    # The classic (per-slot) document from a gate-off sim.
    var classic = newPaintballSim(paintballConfigJson(
      paintBuff = false, hill = false, floorPaint = false, loadout = "ctf"))
    for key in parseJson(classic.playerResultsJson()).keys:
      check key in schemaKeys

  test "the reason and endRule enums are the closed sets the sim can emit":
    let props = game["results_schema"]["properties"]
    var reasons: seq[string]
    for value in props["reason"]["enum"]:
      reasons.add(value.getStr())
    check reasons == @[ReasonComplete, ReasonDeadline, ReasonFault]
    var rules: seq[string]
    for value in props["endRule"]["enum"]:
      rules.add(value.getStr())
    for rule in [EndRuleFullTime, EndRuleMercy, EndRuleWipe, EndRuleWallClock,
                 EndRuleSimFault, EndRuleHostError]:
      check rule in rules

  test "every config key a variant or the fixture uses is in config_schema":
    ## The real constraint: the CLI validates each game_config against
    ## config_schema with additionalProperties false, injecting `tokens`.
    let props = game["config_schema"]["properties"]
    check game["config_schema"]["additionalProperties"].getBool() == false
    var configs = @[manifest["certification"]["game_config"]]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    for variant in archive["variants"]:
      configs.add(variant["game_config"])
    for config in configs:
      for key in config.keys:
        check props.hasKey(key)

  test "every ARRAY property in config_schema declares minItems and maxItems":
    ## The tandem 0.1.0 scar: cert fails `manifest_invalid` otherwise.
    let props = game["config_schema"]["properties"]
    for key, prop in props:
      if prop{"type"}.getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "the replay viewer is the STATIC bundle, never a pod":
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"

  test "the paintball variant settles inside 60% of episodeTimeoutSeconds":
    ## The engine's wall-clock stop must fire before the platform's episode
    ## timeout silently discards the episode, and the worst-case turn
    ## arithmetic (attempt1 + retry, spacing floored) must fit inside it.
    let defaults = defaultGameConfig()
    check defaults.attempt1Ms + defaults.retryMs == 9000
    const
      LobbyCapSeconds = 100
      PlayCapSeconds = 180
      TailSeconds = 20
    for variant in archive["variants"]:
      let cfg = variant["game_config"]
      if not cfg.hasKey("wallClockBudgetSeconds"):
        continue                       ## a classic variant: no LLM turn loop.
      let
        budget = cfg["wallClockBudgetSeconds"].getInt()
        turnsPerGame = cfg["maxTicks"].getInt() div cfg["turnTicks"].getInt()
        turns = turnsPerGame * cfg["maxGames"].getInt()
        worstTurnMs = max(
          defaults.attempt1Ms + defaults.retryMs, cfg["turnSpacingMs"].getInt())
        worstSeconds = turns * worstTurnMs div 1000 +
          LobbyCapSeconds + PlayCapSeconds + TailSeconds
      check budget <= EpisodeTimeoutSeconds * 6 div 10
      check turns <= 40
      check worstTurnMs <= cfg["turnBudgetMs"].getInt()
      check worstSeconds <= budget

  test "hosted LLM uses the native gateway without provider secrets":
    let name = game["name"].getStr()
    check name == "paintbot"
    check "_" notin name
    doAssert game{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.isNil,
      "hosted LLM uses the platform sidecar without provider secrets"
    check game["runnable"]["run"][0].getStr() == "/bin/ctf"
