## The wasm policy runtime for game-hosted seats.
##
## One `PolicyRuntime` owns one wasmtime Engine + Store + Instance for one
## seat's policy module. The module is a wasm32 core module that may import
## WASI preview 1 (no filesystem preopens, no network; stdout/stderr are
## inherited, which the policy host points at the seat log) plus the
## `policy` host namespace:
##
##   send(ptr, len) -> i32        queue one seat->server packet
##   log(level, ptr, len)         one seat-log line
##   llm_chat(ptr, len) -> i32    OpenAI chat-completions request body in;
##                                returns the response length, or a negative
##                                PolicyLlm* error
##   llm_read(dst, cap) -> i32    copies the last llm_chat response into the
##                                guest; returns bytes copied
##
## Exports the module must provide: `memory`, `policy_alloc(len) -> ptr`,
## `policy_init(slot) -> i32`, `policy_on_message(ptr, len) -> i32`;
## `_initialize` is called once when exported (wasi reactor constructors).
##
## Budgets: fuel per guest call plus an epoch wall-clock backstop; host calls
## (the LLM roundtrip) are excluded from the wall budget by re-arming the
## deadline when they return. Memory is capped by the store limiter. A trap
## or budget exhaustion is terminal for the instance: the host reports it
## and the policy-host process exits.

import std/[atomics, os, strutils]
import ../shell/wasmtime_c
import ./llm_proxy

const
  PolicyMaxMemoryBytes* = 64 * 1024 * 1024
  PolicyMaxWasmStackBytes* = 1024 * 1024
  PolicyEpochPeriodMs* = 5
  PolicyCallDeadlineTicks* = 200          ## 1 s of guest time per call
  PolicyInitFuel* = 20_000_000_000'u64
  PolicyMessageFuel* = 2_000_000_000'u64
  PolicyMaxSendBytes* = 262158            ## the largest legal play packet
  PolicyMaxLogBytes* = 4096
  PolicyMaxLlmRequestBytes* = 262144
  PolicyMaxSendsPerCall* = 64

  PolicyLlmUnavailable* = -1'i32
  PolicyLlmBudgetExhausted* = -2'i32
  PolicyLlmHttpError* = -3'i32
  PolicyLlmBadRequest* = -4'i32

type
  WasiConfig {.importc: "wasi_config_t", header: WasmtimeHeader.} = object

  PolicyRuntimeError* = object of CatchableError
  PolicyFault* = object of PolicyRuntimeError
    ## The guest trapped, ran out of budget, or returned nonzero.

  EpochTicker = object
    engine: ptr WasmEngine
    stopped: Atomic[bool]

  HostState = object
    outbox: seq[string]
    faultReason: string
    llm: LlmProxy
    llmResponse: string
    logSink: proc(level: int32, text: string) {.gcsafe.}
    inCall: bool

  PolicyRuntime* = ref object
    engine: ptr WasmEngine
    module: ptr WasmtimeModule
    linker: ptr WasmtimeLinker
    store: ptr WasmtimeStore
    context: ptr WasmtimeContext
    instance: WasmtimeInstance
    memory: WasmtimeMemory
    allocFn, initFn, onMessageFn: WasmtimeFunc
    host: ptr HostState
    ticker: Thread[ptr EpochTicker]
    tickerState: ptr EpochTicker
    closed: bool

proc wasiConfigNew(): ptr WasiConfig {.importc: "wasi_config_new",
  header: WasmtimeHeader.}
proc wasiConfigInheritStdout(config: ptr WasiConfig) {.
  importc: "wasi_config_inherit_stdout", header: WasmtimeHeader.}
proc wasiConfigInheritStderr(config: ptr WasiConfig) {.
  importc: "wasi_config_inherit_stderr", header: WasmtimeHeader.}
proc wasiConfigSetArgv(config: ptr WasiConfig; argc: csize_t;
  argv: cstringArray): bool {.importc: "wasi_config_set_argv",
  header: WasmtimeHeader.}
proc wasmtimeContextSetWasi(context: ptr WasmtimeContext;
  config: ptr WasiConfig): ptr WasmtimeError {.
  importc: "wasmtime_context_set_wasi", header: WasmtimeHeader.}
proc wasmtimeLinkerDefineWasi(linker: ptr WasmtimeLinker): ptr WasmtimeError {.
  importc: "wasmtime_linker_define_wasi", header: WasmtimeHeader.}

proc byteVecString(bytes: WasmByteVec): string =
  result = newString(bytes.size.int)
  if bytes.size > 0:
    copyMem(addr result[0], bytes.data, bytes.size.int)

proc consumeError(error: ptr WasmtimeError): string =
  var message: WasmByteVec
  wasmtimeErrorMessage(error, addr message)
  result = byteVecString(message)
  wasmByteVecDelete(addr message)
  wasmtimeErrorDelete(error)

proc consumeTrap(trap: ptr WasmTrap): string =
  var message: WasmByteVec
  wasmTrapMessage(trap, addr message)
  result = byteVecString(message)
  wasmByteVecDelete(addr message)
  wasmTrapDelete(trap)

proc requireNoError(error: ptr WasmtimeError; operation: string) =
  if error != nil:
    raise newException(PolicyRuntimeError,
      operation & ": " & consumeError(error))

proc tickerMain(state: ptr EpochTicker) {.thread.} =
  while not state.stopped.load(moAcquire):
    sleep(PolicyEpochPeriodMs)
    if state.stopped.load(moAcquire):
      break
    wasmtimeEngineIncrementEpoch(state.engine)

# ---- guest memory helpers -------------------------------------------------

proc guestMemory(caller: ptr WasmtimeCaller): tuple[base: ptr uint8, size: int] =
  var memoryItem: WasmtimeExtern
  if not wasmtimeCallerExportGet(caller, "memory", 6, addr memoryItem):
    raise newException(PolicyRuntimeError, "host call has no memory export")
  defer: wasmtimeExternDelete(addr memoryItem)
  if shellWasmtimeExternKind(addr memoryItem) != WasmtimeExternMemory:
    raise newException(PolicyRuntimeError, "memory export has the wrong kind")
  let context = wasmtimeCallerContext(caller)
  let memory = shellWasmtimeExternMemory(addr memoryItem)
  (wasmtimeMemoryData(context, memory),
    wasmtimeMemoryDataSize(context, memory).int)

proc guestBytes(caller: ptr WasmtimeCaller; ptrValue, lenValue: int32;
                limit: int): string =
  if ptrValue < 0 or lenValue < 0 or lenValue > limit:
    raise newException(PolicyRuntimeError, "invalid guest byte range")
  let (base, size) = caller.guestMemory()
  let stop = int64(ptrValue) + int64(lenValue)
  if stop > int64(size):
    raise newException(PolicyRuntimeError, "guest byte range exceeds memory")
  result = newString(lenValue)
  if lenValue > 0:
    copyMem(addr result[0], cast[pointer](cast[uint](base) + uint(ptrValue)),
      lenValue)

proc writeGuestBytes(caller: ptr WasmtimeCaller; dst, cap: int32;
                     bytes: string): int32 =
  if dst < 0 or cap < 0:
    raise newException(PolicyRuntimeError, "invalid guest destination")
  let (base, size) = caller.guestMemory()
  let count = min(bytes.len, cap.int)
  if int64(dst) + int64(count) > int64(size):
    raise newException(PolicyRuntimeError, "guest destination exceeds memory")
  if count > 0:
    copyMem(cast[pointer](cast[uint](base) + uint(dst)), unsafeAddr bytes[0],
      count)
  int32(count)

template hostStateOf(env: pointer): ptr HostState = cast[ptr HostState](env)

proc i32Arg(args: ptr WasmtimeConstVal; index: int): int32 =
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  shellWasmtimeValI32Get(addr values[index])

# ---- host functions -------------------------------------------------------

proc sendCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = hostStateOf(env)
  if host == nil or nargs != 2 or nresults != 1:
    return nil
  try:
    if host.outbox.len >= PolicyMaxSendsPerCall:
      shellWasmtimeValI32Set(results, -2)
      return nil
    let bytes = guestBytes(caller, args.i32Arg(0), args.i32Arg(1),
      PolicyMaxSendBytes)
    host.outbox.add(bytes)
    shellWasmtimeValI32Set(results, 0)
  except CatchableError as error:
    host.faultReason = "send: " & error.msg
    shellWasmtimeValI32Set(results, -1)

proc logCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = hostStateOf(env)
  if host == nil or nargs != 3 or nresults != 0:
    return nil
  try:
    let text = guestBytes(caller, args.i32Arg(1), args.i32Arg(2),
      PolicyMaxLogBytes)
    if host.logSink != nil:
      host.logSink(args.i32Arg(0), text)
  except CatchableError as error:
    host.faultReason = "log: " & error.msg

proc llmChatCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = hostStateOf(env)
  if host == nil or nargs != 2 or nresults != 1:
    return nil
  host.llmResponse = ""
  try:
    let body = guestBytes(caller, args.i32Arg(0), args.i32Arg(1),
      PolicyMaxLlmRequestBytes)
    if body.len == 0:
      shellWasmtimeValI32Set(results, PolicyLlmBadRequest)
      return nil
    if not host.llm.available:
      shellWasmtimeValI32Set(results, PolicyLlmUnavailable)
      return nil
    if not host.llm.budgetLeft:
      shellWasmtimeValI32Set(results, PolicyLlmBudgetExhausted)
      return nil
    let outcome = host.llm.chat(body)
    # The roundtrip ran on the host clock; give the guest a fresh wall budget
    # so a 30 s model call is not charged against its 1 s deadline.
    wasmtimeContextSetEpochDeadline(wasmtimeCallerContext(caller),
      PolicyCallDeadlineTicks.uint64)
    host.llmResponse = outcome.body
    if outcome.ok:
      shellWasmtimeValI32Set(results, int32(host.llmResponse.len))
    else:
      shellWasmtimeValI32Set(results, PolicyLlmHttpError)
  except CatchableError as error:
    host.faultReason = "llm_chat: " & error.msg
    shellWasmtimeValI32Set(results, PolicyLlmUnavailable)

proc llmReadCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = hostStateOf(env)
  if host == nil or nargs != 2 or nresults != 1:
    return nil
  try:
    shellWasmtimeValI32Set(results,
      writeGuestBytes(caller, args.i32Arg(0), args.i32Arg(1), host.llmResponse))
  except CatchableError as error:
    host.faultReason = "llm_read: " & error.msg
    shellWasmtimeValI32Set(results, -1)

proc defineHostFunc(linker: ptr WasmtimeLinker; name: string;
    functionType: ptr WasmFuncType; callback: WasmtimeCallback;
    env: pointer) =
  let error = shellWasmtimeLinkerDefineFunc(linker, "policy", 6,
    name.cstring, name.len.csize_t, functionType, callback, env)
  wasmFuncTypeDelete(functionType)
  requireNoError(error, "define policy." & name)

# ---- lifecycle ------------------------------------------------------------

proc close*(runtime: PolicyRuntime) =
  if runtime == nil or runtime.closed:
    return
  runtime.closed = true
  if runtime.tickerState != nil:
    runtime.tickerState.stopped.store(true, moRelease)
    joinThread(runtime.ticker)
    deallocShared(runtime.tickerState)
    runtime.tickerState = nil
  if runtime.store != nil:
    wasmtimeStoreDelete(runtime.store)
    runtime.store = nil
  if runtime.linker != nil:
    wasmtimeLinkerDelete(runtime.linker)
    runtime.linker = nil
  if runtime.module != nil:
    wasmtimeModuleDelete(runtime.module)
    runtime.module = nil
  if runtime.engine != nil:
    wasmEngineDelete(runtime.engine)
    runtime.engine = nil
  if runtime.host != nil:
    `=destroy`(runtime.host[])
    deallocShared(runtime.host)
    runtime.host = nil

proc newEngine(): ptr WasmEngine =
  let config = wasmConfigNew()
  if config == nil:
    raise newException(PolicyRuntimeError, "wasm_config_new returned nil")
  wasmtimeConfigStrategySet(config, WasmtimeStrategyCranelift)
  wasmtimeConfigConsumeFuelSet(config, true)
  wasmtimeConfigEpochInterruptionSet(config, true)
  wasmtimeConfigMaxWasmStackSet(config, PolicyMaxWasmStackBytes.csize_t)
  wasmtimeConfigCraneliftNanCanonicalizationSet(config, true)
  wasmtimeConfigWasmThreadsSet(config, false)
  wasmtimeConfigSharedMemorySet(config, false)
  wasmtimeConfigWasmMemory64Set(config, false)
  when defined(macosx):
    wasmtimeConfigMacosUseMachPortsSet(config, true)
  result = wasmEngineNewWithConfig(config)
  if result == nil:
    raise newException(PolicyRuntimeError,
      "wasmtime rejected the policy engine configuration")

proc exportedFunc(runtime: PolicyRuntime; name: string;
                  required: bool): tuple[found: bool, fn: WasmtimeFunc] =
  var item: WasmtimeExtern
  if not wasmtimeInstanceExportGet(runtime.context, addr runtime.instance,
      name.cstring, name.len.csize_t, addr item):
    if required:
      raise newException(PolicyRuntimeError,
        "policy module does not export " & name)
    return (false, result.fn)
  defer: wasmtimeExternDelete(addr item)
  if shellWasmtimeExternKind(addr item) != WasmtimeExternFunc:
    raise newException(PolicyRuntimeError,
      "policy export " & name & " is not a function")
  copyMem(addr result.fn, shellWasmtimeExternFunc(addr item),
    shellWasmtimeFuncSize().int)
  result.found = true

proc callGuest(runtime: PolicyRuntime; fn: var WasmtimeFunc;
               args: var openArray[WasmtimeVal];
               results: var openArray[WasmtimeVal]; what: string) =
  var trap: ptr WasmTrap
  let argsPtr = (if args.len == 0: nil else: addr args[0])
  let resultsPtr = (if results.len == 0: nil else: addr results[0])
  let error = wasmtimeFuncCall(runtime.context, addr fn, argsPtr,
    args.len.csize_t, resultsPtr, results.len.csize_t, addr trap)
  if error != nil:
    if trap != nil:
      discard consumeTrap(trap)
    raise newException(PolicyFault, what & " failed: " & consumeError(error))
  if trap != nil:
    raise newException(PolicyFault, what & " trapped: " & consumeTrap(trap))
  if runtime.host.faultReason.len > 0:
    let reason = runtime.host.faultReason
    runtime.host.faultReason = ""
    raise newException(PolicyFault, what & " host fault: " & reason)

proc arm(runtime: PolicyRuntime; fuel: uint64) =
  requireNoError(wasmtimeContextSetFuel(runtime.context, fuel), "set fuel")
  wasmtimeContextSetEpochDeadline(runtime.context,
    PolicyCallDeadlineTicks.uint64)

proc newPolicyRuntime*(moduleBytes: string; llm: LlmProxy;
    logSink: proc(level: int32, text: string) {.gcsafe.}): PolicyRuntime =
  ## Compiles, links, and instantiates one policy module. Raises
  ## PolicyRuntimeError for a module that does not fit the contract.
  if moduleBytes.len == 0:
    raise newException(PolicyRuntimeError, "policy file is empty")
  new(result)
  let runtime = result
  try:
    runtime.engine = newEngine()
    runtime.tickerState = cast[ptr EpochTicker](
      allocShared0(sizeof(EpochTicker)))
    runtime.tickerState.engine = runtime.engine
    runtime.tickerState.stopped.store(false, moRelaxed)
    createThread(runtime.ticker, tickerMain, runtime.tickerState)

    requireNoError(wasmtimeModuleValidate(runtime.engine,
      cast[ptr uint8](unsafeAddr moduleBytes[0]), moduleBytes.len.csize_t),
      "policy module validation")
    requireNoError(wasmtimeModuleNew(runtime.engine,
      cast[ptr uint8](unsafeAddr moduleBytes[0]), moduleBytes.len.csize_t,
      addr runtime.module), "policy module compilation")

    runtime.host = cast[ptr HostState](allocShared0(sizeof(HostState)))
    runtime.host[] = HostState(llm: llm, logSink: logSink)

    runtime.linker = wasmtimeLinkerNew(runtime.engine)
    requireNoError(wasmtimeLinkerDefineWasi(runtime.linker), "link WASI")
    defineHostFunc(runtime.linker, "send", shellWasmtimeEmitFuncType(),
      sendCallback, runtime.host)
    defineHostFunc(runtime.linker, "log", shellWasmtimeLogFuncType(),
      logCallback, runtime.host)
    defineHostFunc(runtime.linker, "llm_chat", shellWasmtimeEmitFuncType(),
      llmChatCallback, runtime.host)
    defineHostFunc(runtime.linker, "llm_read", shellWasmtimeEmitFuncType(),
      llmReadCallback, runtime.host)

    runtime.store = wasmtimeStoreNew(runtime.engine, nil, nil)
    if runtime.store == nil:
      raise newException(PolicyRuntimeError, "wasmtime_store_new returned nil")
    runtime.context = wasmtimeStoreContext(runtime.store)
    wasmtimeStoreLimiter(runtime.store, PolicyMaxMemoryBytes.int64,
      -1, 1, 4, 1)
    let wasi = wasiConfigNew()
    if wasi == nil:
      raise newException(PolicyRuntimeError, "wasi_config_new returned nil")
    wasiConfigInheritStdout(wasi)
    wasiConfigInheritStderr(wasi)
    let argv = allocCStringArray(["policy"])
    discard wasiConfigSetArgv(wasi, 1, argv)
    deallocCStringArray(argv)
    requireNoError(wasmtimeContextSetWasi(runtime.context, wasi), "set WASI")

    runtime.arm(PolicyInitFuel)
    var trap: ptr WasmTrap
    let error = wasmtimeLinkerInstantiate(runtime.linker, runtime.context,
      runtime.module, addr runtime.instance, addr trap)
    if error != nil:
      if trap != nil:
        discard consumeTrap(trap)
      raise newException(PolicyRuntimeError,
        "policy instantiation: " & consumeError(error))
    if trap != nil:
      raise newException(PolicyFault,
        "policy instantiation trapped: " & consumeTrap(trap))

    block memory:
      var item: WasmtimeExtern
      if not wasmtimeInstanceExportGet(runtime.context, addr runtime.instance,
          "memory", 6, addr item):
        raise newException(PolicyRuntimeError,
          "policy module does not export memory")
      defer: wasmtimeExternDelete(addr item)
      if shellWasmtimeExternKind(addr item) != WasmtimeExternMemory:
        raise newException(PolicyRuntimeError,
          "policy export memory is not a memory")
      copyMem(addr runtime.memory, shellWasmtimeExternMemory(addr item),
        shellWasmtimeMemorySize().int)

    runtime.allocFn = runtime.exportedFunc("policy_alloc", true).fn
    runtime.initFn = runtime.exportedFunc("policy_init", true).fn
    runtime.onMessageFn = runtime.exportedFunc("policy_on_message", true).fn
    let initialize = runtime.exportedFunc("_initialize", false)
    if initialize.found:
      var fn = initialize.fn
      var noArgs: array[0, WasmtimeVal]
      var noResults: array[0, WasmtimeVal]
      runtime.callGuest(fn, noArgs, noResults, "_initialize")
  except CatchableError:
    runtime.close()
    raise

proc allocGuest(runtime: PolicyRuntime; len: int): int32 =
  var args: array[1, WasmtimeVal]
  var results: array[1, WasmtimeVal]
  shellWasmtimeValI32Set(addr args[0], int32(len))
  runtime.callGuest(runtime.allocFn, args, results, "policy_alloc")
  result = shellWasmtimeValI32Get(addr results[0])
  let size = wasmtimeMemoryDataSize(runtime.context, addr runtime.memory).int
  if result <= 0 or int64(result) + int64(len) > int64(size):
    raise newException(PolicyFault,
      "policy_alloc returned an out-of-range buffer")

proc takeOutbox*(runtime: PolicyRuntime): seq[string] =
  result = move(runtime.host.outbox)
  runtime.host.outbox = @[]

proc init*(runtime: PolicyRuntime; slot: int) =
  ## policy_init(slot); raises PolicyFault when it traps or returns nonzero.
  runtime.arm(PolicyInitFuel)
  var args: array[1, WasmtimeVal]
  var results: array[1, WasmtimeVal]
  shellWasmtimeValI32Set(addr args[0], int32(slot))
  runtime.callGuest(runtime.initFn, args, results, "policy_init")
  let code = shellWasmtimeValI32Get(addr results[0])
  if code != 0:
    raise newException(PolicyFault, "policy_init returned " & $code)

proc onMessage*(runtime: PolicyRuntime; message: string) =
  ## Delivers one server->seat message; the replies land in the outbox.
  runtime.arm(PolicyMessageFuel)
  let dst = runtime.allocGuest(max(1, message.len))
  if message.len > 0:
    let base = wasmtimeMemoryData(runtime.context, addr runtime.memory)
    copyMem(cast[pointer](cast[uint](base) + uint(dst)), unsafeAddr message[0],
      message.len)
  var args: array[2, WasmtimeVal]
  var results: array[1, WasmtimeVal]
  shellWasmtimeValI32Set(addr args[0], dst)
  shellWasmtimeValI32Set(addr args[1], int32(message.len))
  runtime.callGuest(runtime.onMessageFn, args, results, "policy_on_message")
  let code = shellWasmtimeValI32Get(addr results[0])
  if code != 0:
    raise newException(PolicyFault, "policy_on_message returned " & $code)

proc llmCalls*(runtime: PolicyRuntime): int =
  if runtime == nil or runtime.host == nil: 0 else: runtime.host.llm.calls

proc wasmtimeVersionString*(): string =
  $shellWasmtimeVersion()
