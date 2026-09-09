## The policy host's LLM route: OpenAI-compatible chat completions, reached
## the way a hosted policy pod reaches a model.
##
##   hosted  POST $AWS_ENDPOINT_URL_BEDROCK_RUNTIME/v1/chat/completions with
##           `X-Coworld-Player-Slot: <slot>` — the sidecar is the GAME's in a
##           game-hosted episode, so the slot header is what attributes spend
##           and rate limits to the seat (roles/GAME.md, "Bedrock and AWS").
##   direct  ANTHROPIC_API_KEY (or ANTHROPIC_API_KEY_URI, the manifest's game
##           secret): the OpenAI-shaped request is translated to the Anthropic
##           Messages API and the reply back, so a policy never sees the
##           difference. Used locally and as the hosted fallback when no
##           sidecar is wired.
##   dev     POST https://openrouter.ai/api/v1/chat/completions with
##           OPENROUTER_API_KEY as the bearer.
##   none    `available` is false; the guest gets PolicyLlmUnavailable and
##           plays its scripted fallback. Local certification stays offline.
##
## POLICY_LLM_MODEL on the game overrides the model every policy asks for.
##
## Every call is timeout-bounded and counted against a per-episode budget.

import std/[json, os, strutils, times]
import bitworld/runtime
import curly, webby

const
  DefaultTimeoutSeconds = 45
  DefaultMaxCalls = 24
  SidecarEndpointEnv = "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"
  OpenRouterUrl = "https://openrouter.ai/api/v1/chat/completions"
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"

type
  LlmRoute = enum
    lrNone, lrSidecar, lrAnthropic, lrOpenRouter

  LlmProxy* = ref object
    route: LlmRoute
    url: string
    apiKey: string
    modelOverride: string
    slot: int
    curl: Curly
    timeoutSeconds: int
    maxCalls*: int
    calls*: int
    label*: string

  LlmOutcome* = object
    ok*: bool
    code*: int
    body*: string

proc newLlmProxy*(slot: int): LlmProxy =
  ## Picks the route from the environment; `POLICY_LLM_MAX_CALLS` and
  ## `POLICY_LLM_TIMEOUT_SECONDS` override the budget.
  new(result)
  result.slot = slot
  result.timeoutSeconds = DefaultTimeoutSeconds
  result.maxCalls = DefaultMaxCalls
  let maxCalls = getEnv("POLICY_LLM_MAX_CALLS")
  if maxCalls.len > 0:
    try: result.maxCalls = parseInt(maxCalls)
    except ValueError: discard
  let timeout = getEnv("POLICY_LLM_TIMEOUT_SECONDS")
  if timeout.len > 0:
    try: result.timeoutSeconds = parseInt(timeout)
    except ValueError: discard
  result.modelOverride = getEnv("POLICY_LLM_MODEL")
  let sidecar = getEnv(SidecarEndpointEnv)
  var anthropicKey = getEnv("ANTHROPIC_API_KEY")
  if anthropicKey.len == 0 and getEnv("ANTHROPIC_API_KEY_URI").len > 0:
    try:
      anthropicKey = readCogameEnv("ANTHROPIC_API_KEY_URI").strip()
    except CatchableError:
      anthropicKey = ""
  if sidecar.len > 0:
    result.route = lrSidecar
    result.url = sidecar.strip(chars = {'/'}, leading = false) &
      "/v1/chat/completions"
    result.label = "sidecar"
  elif anthropicKey.len > 0:
    result.route = lrAnthropic
    result.url = AnthropicUrl
    result.apiKey = anthropicKey
    result.label = "anthropic"
  elif getEnv("OPENROUTER_API_KEY").len > 0:
    result.route = lrOpenRouter
    result.url = OpenRouterUrl
    result.apiKey = getEnv("OPENROUTER_API_KEY")
    result.label = "openrouter"
  else:
    result.label = "none"
  if result.url.len > 0:
    result.curl = newCurly(maxInFlight = 2)

proc available*(proxy: LlmProxy): bool =
  proxy != nil and proxy.url.len > 0

proc budgetLeft*(proxy: LlmProxy): bool =
  proxy.calls < proxy.maxCalls

proc retryDelaySeconds(headers: HttpHeaders): float =
  if "Retry-After-Ms" in headers:
    try: return parseFloat(headers["Retry-After-Ms"]) / 1000.0
    except ValueError: discard
  if "Retry-After" in headers:
    try: return parseFloat(headers["Retry-After"])
    except ValueError: discard
  2.0

proc anthropicModel(slug: string): string =
  ## "anthropic/claude-haiku-4.5" -> "claude-haiku-4-5" (an Anthropic alias);
  ## a bare Anthropic id passes through.
  result = slug
  if result.startsWith("anthropic/"):
    result = result[10 .. ^1]
  if result.startsWith("claude-"):
    result = result.replace(".", "-")

proc toAnthropicRequest(body: string, modelOverride: string): string =
  ## The OpenAI chat-completions request as an Anthropic Messages request.
  let node = parseJson(body)
  var model = node{"model"}.getStr("claude-haiku-4-5")
  if modelOverride.len > 0:
    model = modelOverride
  var request = %*{"model": anthropicModel(model),
    "max_tokens": node{"max_tokens"}.getInt(600)}
  if node{"temperature"} != nil:
    request["temperature"] = node["temperature"]
  var system = ""
  var messages = newJArray()
  if node{"messages"} != nil:
    for message in node["messages"]:
      let role = message{"role"}.getStr("user")
      let content = message{"content"}.getStr("")
      if role == "system":
        if system.len > 0: system.add("\n\n")
        system.add(content)
      else:
        messages.add(%*{"role": (if role == "assistant": "assistant" else: "user"),
          "content": content})
  if system.len > 0:
    request["system"] = %system
  if messages.len == 0:
    messages.add(%*{"role": "user", "content": "Reply with the JSON object."})
  request["messages"] = messages
  $request

proc fromAnthropicResponse(body: string): string =
  ## The Anthropic Messages reply reshaped as a chat-completions reply.
  let node = parseJson(body)
  var text = ""
  if node{"content"} != nil:
    for part in node["content"]:
      if part{"type"}.getStr("") == "text":
        text.add(part{"text"}.getStr(""))
  $(%*{"choices": [{"index": 0, "finish_reason": node{"stop_reason"}.getStr("stop"),
      "message": {"role": "assistant", "content": text}}],
    "model": node{"model"}.getStr(""), "usage": node{"usage"}})

proc applyModelOverride(body, model: string): string =
  if model.len == 0:
    return body
  try:
    var node = parseJson(body)
    node["model"] = %model
    $node
  except CatchableError:
    body

proc chat*(proxy: LlmProxy; body: string): LlmOutcome =
  ## One chat-completions call; the body is the guest's request JSON. A 429
  ## is retried once after the advertised delay. Never raises: the guest
  ## reads the outcome code and body.
  if not proxy.available:
    return LlmOutcome(ok: false, code: 0, body: "llm route unavailable")
  inc proxy.calls
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  var request = body
  case proxy.route
  of lrSidecar:
    headers["X-Coworld-Player-Slot"] = $proxy.slot
    request = applyModelOverride(body, proxy.modelOverride)
  of lrOpenRouter:
    headers["Authorization"] = "Bearer " & proxy.apiKey
    headers["X-Title"] = "paintbot-wasm policy-host"
    request = applyModelOverride(body, proxy.modelOverride)
  of lrAnthropic:
    headers["x-api-key"] = proxy.apiKey
    headers["anthropic-version"] = AnthropicVersion
    try:
      request = toAnthropicRequest(body, proxy.modelOverride)
    except CatchableError as error:
      return LlmOutcome(ok: false, code: 0,
        body: "request is not a chat-completions body: " & error.msg)
  of lrNone:
    discard
  for attempt in 0 .. 1:
    var response: Response
    try:
      response = proxy.curl.post(proxy.url, headers, request,
        proxy.timeoutSeconds)
    except CatchableError as error:
      return LlmOutcome(ok: false, code: 0,
        body: "chat completions unreachable: " & error.msg)
    if response.code == 429 and attempt == 0:
      let delay = min(10.0, max(0.5, retryDelaySeconds(response.headers)))
      sleep(int(delay * 1000))
      continue
    let ok = response.code >= 200 and response.code < 300
    var responseBody = response.body
    if ok and proxy.route == lrAnthropic:
      try:
        responseBody = fromAnthropicResponse(response.body)
      except CatchableError as error:
        return LlmOutcome(ok: false, code: response.code,
          body: "unreadable Anthropic reply: " & error.msg)
    return LlmOutcome(ok: ok, code: response.code, body: responseBody)
  LlmOutcome(ok: false, code: 429, body: "stayed rate limited")

proc describe*(proxy: LlmProxy): string =
  if not proxy.available:
    "no LLM route (set " & SidecarEndpointEnv & ", ANTHROPIC_API_KEY, or OPENROUTER_API_KEY)"
  else:
    proxy.label & " " & proxy.url & " budget=" & $proxy.maxCalls & " calls" &
      (if proxy.modelOverride.len > 0: " model=" & proxy.modelOverride else: "")

proc timestamp*(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
