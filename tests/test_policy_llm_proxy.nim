## Hosted WASM policy inference must use the native game sidecar.
include "../src/policy/llm_proxy"

putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
putEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://retired.invalid")
for slot in 0 .. 1:
  let proxy = newLlmProxy(slot)
  doAssert proxy.route == lrSidecar
  doAssert proxy.url == "http://127.0.0.1:9100/v1/chat/completions"
  doAssert proxy.slot == slot
  doAssert proxy.modelOverride == "anthropic/claude-haiku-4.5"
echo "native WASM policy transport and model selection passed"
