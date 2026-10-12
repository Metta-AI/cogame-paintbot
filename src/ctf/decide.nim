## The decision layer: the per-turn loop that asks both commanders what their
## squads do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (108 ticks = 4.5 s of sim time), 20
## turns per game, 40 per episode. At each turn the server builds BOTH seats'
## request bodies and issues them as ONE parallel batch — paintball is a
## simultaneous-decision game, so querying seats one after another would
## double the wall clock for no gain. One call per seat per turn covers all of
## that seat's commanded cogs.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `holdline` scripted directive for that turn and a `fallback`
## record names the cause. No failure mode leaves a cog unactuated: the
## control layer always has a directive — this turn's, else last turn's, else
## `holdline`'s.

import
  std/[json, math, monotimes, os, strutils, times],
  curly,
  sim, control, directives, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `holdline`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blHoldline
    result.seats[i].label = "holdline"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc standingOn(under: PaintUnder): string =
  case under
  of puOwn: "own"
  of puEnemy: "enemy"
  of puNone: "none"

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerGame: int
): string =
  ## Everything this seat may legitimately know, in map pixels, rounded to
  ## integers. Built from the seat's OWN fog: enemies appear only where a
  ## commanded cog can see them (or saw them inside the control layer's
  ## memory window, which is intel a commander really has). The other seat's
  ## directive, prompt, note and view are never in here, and no real policy
  ## name ever is — cogs are RED-alpha..delta and nothing else.
  let
    team = Team(seat mod max(1, sim.gameMap.teamCount()))
    other = if team == Red: Blue else: Red
    commanded = sim.commandedCogs(seat)
    size = sim.paintTileSize()
    hill = hillCentre(sim)
    ## The hill's REAL pixel box: the bounding box of its tile block, taken
    ## from the tile list itself. Deriving it from the hill centre instead put
    ## it half a tile out on every side (the centre is the middle of its tile,
    ## not a tile boundary), so the model was told the hill was
    ## [532,244,702,414] where the tiles it must paint are [544,238,713,407].
    box = sim.hillPixelBox()
    played = sim.gameTicksElapsed() div TargetFps
    total = (if sim.config.maxTicks > 0: sim.config.maxTicks div TargetFps
             else: 0)

  var commandedIds = newJArray()
  for cogIndex in commanded:
    commandedIds.add(%sim.cogAlias(cogIndex))

  var cogs = newJArray()
  for cogIndex in commanded:
    let p = sim.players[cogIndex]
    cogs.add(%*{
      "id": sim.cogAlias(cogIndex),
      "pos": [p.x + CollisionW div 2, p.y + CollisionH div 2],
      "aim": p.aimBrads,
      "hp": max(0, p.hp),
      "lives": p.lives,
      "alive": p.alive,
      "standing_on": standingOn(p.paintUnder),
      "spray_ready": p.hasSprayPaint and p.fireCooldown <= 0 and
        p.arcTicksLeft <= 0,
      "dist_to_hill": int(
        distSq(p.x, p.y, hill.x, hill.y).float.sqrt())
    })

  var seen = newJArray()
  for j in 0 ..< sim.players.len:
    if sim.players[j].team == team or not sim.players[j].alive:
      continue
    var
      visible = false
      ticksAgo = 0
      ex = sim.players[j].x
      ey = sim.players[j].y
    for cogIndex in commanded:
      if sim.players[cogIndex].alive and sim.playerVisibleTo(cogIndex, j):
        visible = true
        break
    if not visible:
      for cogIndex in commanded:
        let known = engine.ctl.knownEnemy(sim, cogIndex)
        if known.known and known.index == j:
          visible = true
          ticksAgo = known.ticksAgo
          ex = known.x
          ey = known.y
          break
    if not visible:
      continue
    seen.add(%*{
      "id": sim.cogAlias(j),
      "pos": [ex + CollisionW div 2, ey + CollisionH div 2],
      "hp": max(0, sim.players[j].hp),
      "ticks_ago": ticksAgo
    })

  # In a `visitor` game the seat's three scripted teammates are reported
  # exactly as any other visible ally would be: position and alive flag, no
  # intent. It cannot instruct them and cannot see what they mean to do.
  var mates = newJArray()
  if sim.regime == regimeVisitor:
    for cogIndex in sim.squadCogs(seat):
      if sim.seatCommands(seat, cogIndex):
        continue
      mates.add(%*{
        "id": sim.cogAlias(cogIndex),
        "pos": [sim.players[cogIndex].x + CollisionW div 2,
                sim.players[cogIndex].y + CollisionH div 2],
        "alive": sim.players[cogIndex].alive
      })

  let
    yoursPct = sim.hillCoveragePct(team)
    theirsPct = sim.hillCoveragePct(other)
  var residentDone = newJNull()
  if sim.gameIndex > 0 and sim.gameHill.len > 0:
    let archived = sim.gameHill[0]
    residentDone = %(
      gameScorePermille(archived[team] - archived[other],
                        sim.config.hillDecisiveTicks).float / 1000.0)

  var node = %*{
    "game": sim.gameIndex + 1,
    "of": max(1, sim.config.maxGames),
    "regime": regimeText(sim.regime),
    "turn": turnIndex,
    "turns": turnsPerGame,
    "clock": {"played_s": played, "left_s": max(0, total - played)},
    "you": {"team": toUpperAscii(teamText(team)), "commanding": commandedIds},
    "hill": {
      "box": box,
      "centre": [hill.x, hill.y],
      "floor_tiles": sim.hillFloorTiles,
      "yours_pct": yoursPct,
      "theirs_pct": theirsPct,
      "neutral_pct": max(0, 100 - yoursPct - theirsPct),
      "owner": (if sim.hillOwned: toUpperAscii(teamText(sim.hillOwner))
                else: "none"),
      "need_pct": sim.config.hillOwnPermille div 10,
      "held_s": {
        "you": sim.hillTicks[team] div TargetFps,
        "them": sim.hillTicks[other] div TargetFps
      }
    },
    "score": {
      "you": gameScorePermille(
        sim.hillTicksLead(team), sim.config.hillDecisiveTicks).float / 1000.0,
      "them": gameScorePermille(
        sim.hillTicksLead(other), sim.config.hillDecisiveTicks).float / 1000.0,
      "resident_done": residentDone
    },
    "map": {"w": MapWidth, "h": MapHeight, "tile": size},
    "your_cogs": cogs,
    "seen_enemies": seen,
    "your_paint_near_hill": sim.hillPaint[team],
    "their_paint_near_hill": sim.hillPaint[other],
    "teammates_not_yours": mates
  }
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    node["your_last_directive"] = %engine.directives[seat].note
  else:
    node["your_last_directive"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(
  game, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "game": game,
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  seat: int, team, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "team": team,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end (design §Record
  ## vocabulary, docs/PROTOCOL.md §The replay). It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): SquadDirective =
  scriptedDirective(engine.ctl, sim, kind, sim.commandedCogs(seat))

proc holdlineFor*(
  engine: DecisionEngine, sim: SimServer, cogs: seq[int]
): SquadDirective =
  ## The published `holdline` directive for an arbitrary cog set — used for
  ## the scripted teammates of a `visitor` game as well as for the fallback.
  scriptedDirective(engine.ctl, sim, blHoldline, cogs)

proc repairMissingOrders*(
  engine: DecisionEngine, sim: SimServer, seat: int,
  directive: var SquadDirective
) =
  ## Design §Reply schema, the `cogs` row: "extra entries dropped; a missing
  ## cog keeps LAST turn's directive, else `holdline`'s". The parser fills an
  ## unnamed cog with `paint_hill` at the hill centre so no cog is ever left
  ## unactuated; that default is a floor, not the rule — a commander who names
  ## three of four cogs meant the fourth to carry on, not to abandon its guard
  ## post and walk to the middle.
  var previous: seq[CogOrder]
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    previous = engine.directives[seat].orders
  var
    holdline: SquadDirective
    builtHoldline = false
  for order in directive.orders.mitems:
    if order.fromReply:
      continue
    var repaired = false
    for old in previous:
      if old.cogIndex == order.cogIndex:
        order = old                  ## last turn's directive for this cog
        repaired = true
        break
    if repaired:
      continue
    if not builtHoldline:
      holdline = engine.holdlineFor(sim, sim.commandedCogs(seat))
      builtHoldline = true
    for fallback in holdline.orders:
      if fallback.cogIndex == order.cogIndex:
        order = fallback             ## else holdline's
        break

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex, turnsPerGame: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal directive.
  let
    game = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a daily-token 429 on turn k says nothing
  ## about turn k+1 (the sidecar's window may have rolled), so the flag is
  ## cleared here and only suppresses this turn's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, switch the LLM off for the rest of the episode and finish on the
  # scripted layer (microseconds per turn), so the episode ends
  # complete/full_time instead of deadline.
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "paintball: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens (`no_credentials`, `budget_guard`). Recording it is
      # what makes the two countable: without this an LLM seat with no key
      # reported llmTurns 0 AND fallbackTurns 0, and replay_summary.py's
      # `fallbacks` was 0 for an episode in which nothing but fallbacks
      # happened. A seat that registered as SCRIPTED is not a fallback and
      # gets no record (which is why certification's two baseline seats write
      # none).
      var directive = engine.holdlineFor(sim, sim.commandedCogs(seat))
      directive.source = dsFallback
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(game, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing holdline"))
      echo "paintball llm: seat ", seat, " falling back to holdline (", cause,
        ") on turn ", turnIndex
    else:
      var directive = engine.scriptedFor(
        sim, seat, engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE, and two seats at
  # a fast turn sit right on it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at <= 24 req/min. The cert
  # fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = engine.seatViewJson(sim, seat, turnIndex, turnsPerGame)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with one " &
          "\"cogs\" entry per cog you command.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user), seat)
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — and a config that is not a whole
    # number of seconds is therefore not the deadline it claims to be. 0.1.2
    # shipped `attempt1Ms: 4500` and really ran with 4 s against a sidecar
    # whose median call measured 4618 ms; every successful LLM directive in
    # that release reported a latency of 3999–4001 ms, i.e. it was the
    # deadline answering, not the model. sim_config now REJECTS a sub-second
    # value, so the floor below is an identity: 6000 -> 6 s, 3000 -> 3 s,
    # worst case 9 s inside the 10 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        let commanded = sim.commandedCogs(seat)
        var ids: seq[string]
        for cogIndex in commanded:
          ids.add(sim.cogAlias(cogIndex))
        let hill = hillCentre(sim)
        var directive = parseSquadDirective(
          extractJsonObject(text), ids, commanded,
          hill.x, hill.y, MapWidth - 1, MapHeight - 1)
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.repairMissingOrders(sim, seat, directive)
        engine.directives[seat] = directive
        engine.haveDirective[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made the hosted log unreadable: 205
          ## "falling back (parse_error)" lines for an episode whose only
          ## fault was a daily-token cap.
          cause = "throttled"
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "paintball llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land. Bounded, and recorded as
      # a `fallback` with cause `throttled` by the block below.
      echo "paintball llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays holdline for this turn ---------------------
  for seat in open:
    var directive = engine.holdlineFor(sim, sim.commandedCogs(seat))
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(game, turnIndex, seat, 2, cause,
      "seat fell back to the holdline directive"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "paintball llm: seat ", seat, " falling back to holdline (", cause,
      ") on turn ", turnIndex
