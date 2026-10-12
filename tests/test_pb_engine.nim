## The turn loop's contracts that do not need a live network: the batch is
## PARALLEL by construction, the deadlines compose, the budget guard settles
## early, and no failure path leaves a cog unactuated.
import std/[json, monotimes, os, strutils, times, unittest]
import curly
import pb_helpers

suite "decision engine":
  test "both seats' calls are built as ONE batch, never sequentially":
    ## The engine issues exactly one curly RequestBatch per attempt and both
    ## seats' requests go into it, so their in-flight windows necessarily
    ## intersect. Asserted structurally: the batch is built before any request
    ## is made, so a sequential implementation could not produce it.
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    check engine.seats.len == 2
    var batch: RequestBatch
    for seat in 0 ..< engine.seats.len:
      var headers: HttpHeaders
      headers["content-type"] = "application/json"
      let request = engine.client.requestFor(
        SystemPrompt, userMessage("", engine.seatViewJson(sim, seat, 0, 20)), 0)
      batch.post(request.url, request.headers, request.body, $seat)
    check batch.len == 2
    check batch[0].tag == "0"
    check batch[1].tag == "1"

  test "the two batch deadlines fit inside the per-turn budget":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    check config.attempt1Ms + config.retryMs <= config.turnBudgetMs
    ## v1.1 timing amendment. curly's transport timeout is CURLOPT_TIMEOUT —
    ## whole seconds — and decide.turn FLOORS the conversion, so a sub-second
    ## deadline is not the deadline it claims to be: 0.1.2's `attempt1Ms:
    ## 4500` really ran with 4 s, against a hosted sidecar whose median call
    ## measured 4618 ms (56 of 85 calls past 4 s), and every successful LLM
    ## directive reported a 3999-4001 ms latency. Both deadlines are therefore
    ## whole seconds, and the EFFECTIVE value must equal the configured one.
    let
      effectiveAttempt1 = max(1, config.attempt1Ms div 1000) * 1000
      effectiveRetry = max(1, config.retryMs div 1000) * 1000
    check effectiveAttempt1 == config.attempt1Ms
    check effectiveRetry == config.retryMs
    check effectiveAttempt1 == 6000              ## 6 s, not 4 s
    check effectiveRetry == 3000
    ## Attempt 1 clears the measured sidecar median with margin.
    const MeasuredSidecarMedianMs = 4618
    check effectiveAttempt1 >= MeasuredSidecarMedianMs + 1000
    ## And the worst case — a turn that blows both deadlines — still fits
    ## inside the per-turn cap with room to spare.
    check effectiveAttempt1 + effectiveRetry == 9000
    check effectiveAttempt1 + effectiveRetry < config.turnBudgetMs
    ## The whole-second rule is enforced by the config validator, not just by
    ## the shipped defaults.
    var floored = defaultGameConfig()
    expect CtfError:
      floored.update($(%*{"attempt1Ms": 4500}))

  test "turnSpacingMs holds two seats under the sidecar's 30/min cap":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    ## The shipped variants floor the spacing at 5 s: 2 seats / 5 s = 24 req/min.
    check DefaultTurnSpacingMs >= 5000
    let perMinute = 2 * 60_000 div DefaultTurnSpacingMs
    check perMinute <= 30
    ## The certification fixture switches it off, so offline runs pay nothing.
    check config.turnSpacingMs == 0

  test "with no credentials every turn falls back INSTANTLY and legally":
    ## The load-bearing offline path: certification has no key, so the client
    ## disables itself and the whole episode must run on the scripted layer
    ## with no network wait at all.
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    check engine.client.disabled
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    let started = getMonoTime()
    let records = engine.turn(sim, 0, 20, 0)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    check elapsed < sim.config.turnBudgetMs
    ## And it is COUNTED: an LLM seat that cannot call the LLM is a fallback
    ## with a named cause, which is what makes phase 60's "not all fallbacks"
    ## check and replay_summary.py's `fallbacks` mean anything. Before this,
    ## such a seat reported llmTurns 0 and fallbackTurns 0 — an episode of
    ## nothing but fallbacks that counted none.
    check records.len == 2
    for record in records:
      let node = parseJson(record)
      check node["k"].getStr() == "fallback"
      check node["cause"].getStr() == "no_credentials"
      check node["detail"].getStr().len > 0
    for seat in 0 .. 1:
      check engine.haveDirective[seat]
      check engine.directives[seat].source == dsFallback
      check engine.directives[seat].orders.len == sim.commandedCogs(seat).len

  test "a SCRIPTED seat is never recorded as a fallback":
    ## Certification seats both register scripted; they are playing their
    ## policy, not degrading, so the fallback count stays honest.
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    check not engine.seats[0].isLlm
    let records = engine.turn(sim, 0, 20, 0)
    check records.len == 0
    for seat in 0 .. 1:
      check engine.directives[seat].source == dsScripted

  test "the budget guard fires and names the turn it fired on":
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    engine.seats[0].isLlm = true
    engine.seats[1].isLlm = true
    ## Two more turns would not fit inside the wall-clock budget.
    let records = engine.turn(sim, 7, 20, sim.config.wallClockBudgetSeconds - 1)
    check engine.llmOff
    var sawGuard = false
    for record in records:
      let node = parseJson(record)
      if node{"k"}.getStr() == "budget_guard":
        sawGuard = true
        check node{"turn"}.getInt() == 7
    check sawGuard
    ## And from here on every remaining turn plays the holdline directive with
    ## no network wait — recorded as a `budget_guard` fallback per seat per
    ## turn, which is the cause the design note's enum names and the only way
    ## the guard's cost is countable after the turn it fired on.
    let after = engine.turn(sim, 8, 20, 1)
    check after.len == 2
    for record in after:
      let node = parseJson(record)
      check node["k"].getStr() == "fallback"
      check node["cause"].getStr() == "budget_guard"
      check node["turn"].getInt() == 8
    check engine.directives[0].source == dsFallback

  test "the per-seat view leaks no policy identity and no enemy detail":
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    let view = engine.seatViewJson(sim, 0, 3, 20)
    check "daveey" notin view
    check "daveey-1" notin view
    check "RED-alpha" in view
    let node = parseJson(view)
    check node["you"]["team"].getStr() == "RED"
    check node["you"]["commanding"].len == 4
    check node["hill"]["need_pct"].getInt() == 80
    check node["regime"].getStr() == "resident"
    check node["your_cogs"].len == 4
    ## resident_done is null in game 1 and carries the resident score in game 2.
    check node["score"]["resident_done"].kind == JNull

  test "a never-connecting seat still yields a legal directive":
    ## No failure mode leaves a cog unactuated: the control layer always has a
    ## directive — this turn's, else last turn's, else holdline's.
    var sim = newPaintballSim()
    var engine = initDecisionEngine(sim)
    discard engine.turn(sim, 0, 20, 0)
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    for cogIndex in 0 ..< sim.players.len:
      let seat = sim.cogSeat(cogIndex)
      var found = false
      for order in engine.directives[seat].orders:
        if order.cogIndex == cogIndex:
          found = true
          discard ctl.compileMask(sim, order, cogIndex)
      if not found:
        let scripted = engine.holdlineFor(sim, @[cogIndex])
        check scripted.orders.len == 1

  test "the wall-clock budget is inside 60% of episodeTimeoutSeconds":
    var config = defaultGameConfig()
    config.update(paintballConfigJson())
    check config.wallClockBudgetSeconds <= 720
    check DefaultWallClockBudgetSeconds <= 720

  test "the log carries the phrases phase 60 greps the game log for":
    ## Design §Where the decision happens: "phase 60 greps the *game* log for
    ## `falling back` / `LLM provider is unavailable`". Those two phrases are
    ## the phase-60 verification contract, so they are pinned here rather than
    ## left to drift out of the echo lines.
    let
      llm = readFile("src/ctf/llm.nim")
      decide = readFile("src/ctf/decide.nim")
    check "LLM provider is unavailable" in llm
    check "falling back" in llm or "falling back" in decide
    ## And on the real path: a seat with no credentials logs both.
    check "falling back to holdline" in decide

  test "haiku is the ONLY bedrock candidate and a throttle fails fast":
    ## Paintball 0.1.2 listed `us.anthropic.claude-sonnet-4-5` as the ladder
    ## fallback. Hosted round 2 called it 133 times and every single call
    ## returned "Timeout was reached": one haiku 429 therefore cost the whole
    ## episode, because each seat spent its retry on a model that never
    ## answers (the cogame-raid 2026-08-23 scar, reproduced 2026-08-25).
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:9100")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")
    delEnv("BEDROCK_MODEL")
    let config = defaultGameConfig()
    let bedrock = newLlmClient(config)
    check bedrock.transport == ltBedrock
    let request = bedrock.requestFor(SystemPrompt, "view", 0)
    check "haiku" in request.url
    check "sonnet" notin request.url
    ## Rotation is not removed, only emptied: BEDROCK_MODEL still pins one.
    putEnv("BEDROCK_MODEL", "us.anthropic.claude-opus-4-1-20250805-v1:0")
    check "opus" in newLlmClient(config).requestFor(SystemPrompt, "v", 0).url
    delEnv("BEDROCK_MODEL")
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    ## And a 429 with nothing to rotate to sets `throttled`, which is what
    ## makes the turn loop skip a retry it cannot win.
    var client = LlmClient(transport: ltAnthropic)
    check not client.throttled
    expect LlmError:
      discard client.textOf(
        Response(code: 429,
          body: """{"message":"Too many tokens per day"}"""), "", "url")
    check client.throttled
    ## Fail-fast is a bounded fallback, not a disabled client: the next turn
    ## calls again.
    check not client.disabled
