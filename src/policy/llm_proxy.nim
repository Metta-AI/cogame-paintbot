## The policy host's LLM route: OpenAI-compatible chat completions, reached
## the way a hosted policy pod reaches a model.
##
##   hosted  POST $AWS_ENDPOINT_URL_BEDROCK_RUNTIME/v1/chat/completions with
##           `X-Coworld-Player-Slot: <slot>` — the sidecar is the GAME's in a
##           game-hosted episode, so the slot header is what attributes spend
##           and rate limits to the seat (roles/GAME.md, "Bedrock and AWS").
##   dev     POST https://openrouter.ai/api/v1/chat/completions with
##           OPENROUTER_API_KEY as the bearer.
##   none    `available` is false; the guest gets PolicyLlmUnavailable and
##           plays its scripted fallback. Local certification stays offline.
##
## Every call is timeout-bounded and counted against a per-episode budget.

import std/[os, strutils, times]
import curly, webby

const
  DefaultTimeoutSeconds = 45
  DefaultMaxCalls = 24
  SidecarEndpointEnv = "AWS_ENDPOINT_URL_BEDROCK_RUNTIME"
  OpenRouterUrl = "https://openrouter.ai/api/v1/chat/completions"

type
  LlmProxy* = ref object
    url: string
    apiKey: string
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
  let sidecar = getEnv(SidecarEndpointEnv)
  if sidecar.len > 0:
    result.url = sidecar.strip(chars = {'/'}, leading = false) &
      "/v1/chat/completions"
    result.label = "sidecar"
  elif getEnv("OPENROUTER_API_KEY").len > 0:
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

proc chat*(proxy: LlmProxy; body: string): LlmOutcome =
  ## One chat-completions call; the body is the guest's request JSON. A 429
  ## is retried once after the advertised delay. Never raises: the guest
  ## reads the outcome code and body.
  if not proxy.available:
    return LlmOutcome(ok: false, code: 0, body: "llm route unavailable")
  inc proxy.calls
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  if proxy.apiKey.len > 0:
    headers["Authorization"] = "Bearer " & proxy.apiKey
    headers["X-Title"] = "paintbot-wasm policy-host"
  else:
    headers["X-Coworld-Player-Slot"] = $proxy.slot
  for attempt in 0 .. 1:
    var response: Response
    try:
      response = proxy.curl.post(proxy.url, headers, body,
        proxy.timeoutSeconds)
    except CatchableError as error:
      return LlmOutcome(ok: false, code: 0,
        body: "chat completions unreachable: " & error.msg)
    if response.code == 429 and attempt == 0:
      let delay = min(10.0, max(0.5, retryDelaySeconds(response.headers)))
      sleep(int(delay * 1000))
      continue
    return LlmOutcome(
      ok: response.code >= 200 and response.code < 300,
      code: response.code,
      body: response.body)
  LlmOutcome(ok: false, code: 429, body: "stayed rate limited")

proc describe*(proxy: LlmProxy): string =
  if not proxy.available:
    "no LLM route (set " & SidecarEndpointEnv & " or OPENROUTER_API_KEY)"
  else:
    proxy.label & " " & proxy.url & " budget=" & $proxy.maxCalls & " calls"

proc timestamp*(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
