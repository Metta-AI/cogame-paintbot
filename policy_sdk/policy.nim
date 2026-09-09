## The Nim SDK for a paintbot-wasm policy module (docs/POLICY_WASM.md).
##
## A policy is an event-driven play-seat client: the host calls
## `policy_init(slot)` once and `policy_on_message(bytes)` for every
## server->seat websocket message; the policy answers with `send` (queued
## seat->server packets, written after the call returns), `log` (seat log
## lines), and may ask the host for one synchronous model call with
## `llmChat`. Import this module, then implement `onInit` and `onMessage`
## with `definePolicy`.

import std/strutils

type GuestPtr* = (when defined(paintbotPolicyWasm): int32 else: int)
  ## A guest address: i32 in wasm32, pointer-sized in native test builds.

when defined(paintbotPolicyWasm):
  {.emit: """
void NimMain(void);
static int paintbot_policy_nim_initialized;
__attribute__((constructor))
static void paintbot_policy_nim_init(void) {
  if (!paintbot_policy_nim_initialized) {
    paintbot_policy_nim_initialized = 1;
    NimMain();
  }
}
""".}

  proc policySendRaw(data: int32; length: int32): int32 {.
    importc: "policy_send", cdecl, header: "policy_imports.h".}
  proc policyLogRaw(level: int32; data: int32; length: int32) {.
    importc: "policy_log", cdecl, header: "policy_imports.h".}
  proc policyLlmChatRaw(data: int32; length: int32): int32 {.
    importc: "policy_llm_chat", cdecl, header: "policy_imports.h".}
  proc policyLlmReadRaw(dst: int32; cap: int32): int32 {.
    importc: "policy_llm_read", cdecl, header: "policy_imports.h".}

  proc guestPtr(s: string): int32 =
    if s.len == 0: 0'i32 else: cast[int32](cast[uint](unsafeAddr s[0]))

  proc send*(packet: string): bool =
    ## Queues one seat->server packet. False when the host refused it.
    policySendRaw(guestPtr(packet), int32(packet.len)) == 0

  proc log*(text: string, level = 1'i32) =
    ## One line in the seat log (the host prefixes it with the level).
    policyLogRaw(level, guestPtr(text), int32(text.len))

  const
    LlmUnavailable* = -1'i32
    LlmBudgetExhausted* = -2'i32
    LlmHttpError* = -3'i32
    LlmBadRequest* = -4'i32

  proc llmChat*(requestBody: string): tuple[code: int32, body: string] =
    ## One OpenAI-compatible chat-completions call through the host. `code`
    ## is the response length on success or a negative Llm* error; on an
    ## HTTP error the body carries the server's response.
    let code = policyLlmChatRaw(guestPtr(requestBody), int32(requestBody.len))
    var buffer = newString(65536)
    let copied = policyLlmReadRaw(guestPtr(buffer), int32(buffer.len))
    if copied > 0:
      buffer.setLen(copied)
    else:
      buffer.setLen(0)
    (code, buffer)
else:
  # Native test builds: the host functions are plain procs the test harness
  # can observe.
  var
    sentPackets*: seq[string]
    loggedLines*: seq[string]
    llmStub*: proc(request: string): tuple[code: int32, body: string]

  proc send*(packet: string): bool =
    sentPackets.add(packet)
    true

  proc log*(text: string, level = 1'i32) =
    loggedLines.add(text)

  const
    LlmUnavailable* = -1'i32
    LlmBudgetExhausted* = -2'i32
    LlmHttpError* = -3'i32
    LlmBadRequest* = -4'i32

  proc llmChat*(requestBody: string): tuple[code: int32, body: string] =
    if llmStub == nil:
      return (LlmUnavailable, "")
    llmStub(requestBody)

var arenaBuffers: seq[string]

proc policy_alloc*(length: int32): GuestPtr {.exportc, cdecl.} =
  ## Host->guest buffer for one message. Buffers live until the next
  ## message, which is all the host needs.
  if arenaBuffers.len > 8:
    arenaBuffers.setLen(0)
  var buffer = newString(max(1, int(length)))
  let address = cast[GuestPtr](cast[uint](addr buffer[0]))
  arenaBuffers.add(move(buffer))
  address

template definePolicy*(initBody, messageBody: untyped) =
  ## `initBody` sees `slot: int`; `messageBody` sees `message: string`.
  ## Raising inside either is a policy fault (the seat drops).
  proc policy_init*(slotArg: int32): int32 {.exportc, cdecl.} =
    let slot {.inject.} = int(slotArg)
    try:
      initBody
      0'i32
    except CatchableError as error:
      log("policy_init failed: " & error.msg, 3)
      1'i32

  proc policy_on_message*(data: GuestPtr, length: int32): int32 {.
      exportc, cdecl.} =
    var message {.inject.} = newString(int(length))
    if length > 0:
      copyMem(addr message[0], cast[pointer](cast[uint](data)), int(length))
    try:
      messageBody
      0'i32
    except CatchableError as error:
      log("policy_on_message failed: " & error.msg, 3)
      1'i32

proc hexByte*(value: uint8): string =
  const Digits = "0123456789abcdef"
  result = newString(2)
  result[0] = Digits[int(value shr 4)]
  result[1] = Digits[int(value and 0xf)]

export strutils.strip
