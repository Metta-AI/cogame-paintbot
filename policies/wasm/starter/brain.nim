## The model call, and the canned persona turns that stand in for it
## (ports of brain.OpenAiChatBrain + ResilientBrain + PersonaCannedBrain).
## One live failure of any kind degrades the seat to canned turns for the
## rest of the match: degraded play beats a dead seat.

import std/[json, strutils]
import policy
import ./persona

const
  DefaultModel* = "anthropic/claude-haiku-4.5"
    ## On the platform allowlist; the game's POLICY_LLM_MODEL env can
    ## override it host-side.

type
  Brain* = object
    model*: string
    systemPrompt*: string
    persona: Persona
    cannedTurn: int
    degraded*: bool
    liveCalls*: int
    cannedCalls*: int
    liveEnabled*: bool

proc initBrain*(persona: Persona, systemPrompt: string, liveEnabled: bool): Brain =
  Brain(model: DefaultModel, systemPrompt: systemPrompt, persona: persona,
    liveEnabled: liveEnabled)

proc name*(brain: Brain): string =
  if brain.liveEnabled and not brain.degraded: "live " & brain.model
  else: "canned-" & brain.persona.name

proc canned(brain: var Brain): JsonNode =
  inc brain.cannedCalls
  let turns = brain.persona.cannedTurns
  if turns.len == 0:
    return %*{"call": {"entries": []}}
  result = copy(turns[min(brain.cannedTurn, turns.len - 1)])
  inc brain.cannedTurn

proc parseModelJson*(text: string): JsonNode =
  ## The object a chat model returned, tolerating the wrappers models emit:
  ## bare; inside the first ``` fence; the outermost {...} span.
  var candidates = @[text.strip()]
  let fenceStart = text.find("```")
  if fenceStart >= 0:
    var bodyStart = fenceStart + 3
    while bodyStart < text.len and text[bodyStart] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      inc bodyStart
    if bodyStart < text.len and text[bodyStart] == '\n':
      inc bodyStart
    let fenceEnd = text.find("```", bodyStart)
    if fenceEnd > bodyStart:
      candidates.add(text[bodyStart ..< fenceEnd].strip())
  let first = text.find('{')
  let last = text.rfind('}')
  if first >= 0 and last > first:
    candidates.add(text[first .. last])
  for candidate in candidates:
    try:
      let parsed = parseJson(candidate)
      if parsed.kind == JObject:
        return parsed
    except CatchableError:
      discard
  raise newException(ValueError, "no JSON object in model output")

proc decide*(brain: var Brain, summary: string): JsonNode =
  ## One decision: a live model call when the route is up and the seat has
  ## not degraded, else the persona's next canned turn.
  if not brain.liveEnabled or brain.degraded:
    return brain.canned()
  let request = %*{
    "model": brain.model,
    "response_format": {"type": "json_object"},
    "temperature": 0.4,
    "max_tokens": 600,
    "messages": [
      {"role": "system", "content": brain.systemPrompt},
      {"role": "user", "content": summary}]}
  let (code, body) = llmChat($request)
  if code < 0:
    let why =
      case code
      of LlmUnavailable: "no LLM route"
      of LlmBudgetExhausted: "LLM call budget spent"
      of LlmHttpError: "chat completions error: " & body[0 ..< min(body.len, 400)]
      else: "LLM request refused (" & $code & ")"
    log("model call failed (" & why & "); degrading to canned turns for the rest of the match", 2)
    brain.degraded = true
    return brain.canned()
  inc brain.liveCalls
  try:
    let payload = parseJson(body)
    let content = payload["choices"][0]["message"]["content"].getStr
    return parseModelJson(content)
  except CatchableError as error:
    log("model did not return usable JSON (" & error.msg & "); degrading to canned turns", 2)
    brain.degraded = true
    return brain.canned()
