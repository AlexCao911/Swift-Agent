# Local C++ Inference Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current local C++ inference ABI with a clean v2 local-only engine boundary using opaque handles, explicit memory ownership, compiled-engine registry, model/generation separation, deterministic test coverage, and a vendor-gated LiteRT adapter boundary.

**Architecture:** Swift remains the app-level inference router. Swift chooses `LocalCppInferenceClient` for downloaded local model files and `CloudInferenceClient` for cloud providers. C++ owns only local compiled engine execution: registry, capabilities, model load/unload, generation sessions, token events, cancellation, and stable local errors. The old v1 `local_agent_backend_*` ABI is removed from the C++ public boundary. Rust direct local-LLM C ABI ownership is a migration leftover that is explicitly retired later, in the Swift/Rust HostInference takeover.

**Tech Stack:** C++17, C ABI, clang/clang++, existing `local-ios-agent/inference` tree, mock deterministic backend, llama.cpp adapter, LiteRT adapter boundary with vendor-gated registry exposure, shell contract runner.

## Global Constraints

- Keep C++ local inference only. Do not add cloud HTTP, API keys, provider routing, agent profiles, tool calls, model downloads, model library persistence, or UI.
- Treat this as a breaking local inference refactor. Do not preserve v1 `local_agent_backend_*` behavior.
- The public C ABI after this plan is v2 only: engine handle, model handle, generation handle, string free, last error, and image input.
- Rust must not become the target owner for local engine selection or local model loading. Existing Rust direct-C++ local inference feature flags are retired in this C++ phase and fail fast if enabled; app-facing local inference moves in the later Swift/Rust HostInference takeover.
- Engines are compile-time linked and signed with the app. The registry must not model runtime-downloaded dylibs/frameworks.
- `mock` is test/debug-only. Release-capability checks must prove the public registry does not expose `mock`.
- `llama_cpp` and `litert` are production engine ids. LiteRT adapter-boundary code may compile in tests, but public `litert` registry exposure is allowed only when the LiteRT vendor runtime bridge is linked.
- All returned `char *` JSON/string buffers are allocated by C++ and released by `local_agent_string_free`.
- Callback `const char *token_json` is borrowed and valid only for the callback invocation.
- C++ token events must not include agent-level tool call events. Use `text_delta`, `reasoning_delta`, `structured_delta`, `usage`, `completed`, and `error`.
- Multimodal v2 buffer input copies bytes before `local_agent_generation_start` returns. C++ must not retain caller-owned image pointers.
- Rust direct C++ local inference feature flags are disabled with an explicit retirement message until a later Swift/Rust HostInference takeover gives Swift an app-facing local route.

---

## Current File Map

Existing local inference files:

```text
local-ios-agent/inference/
├── include/local_agent_inference.h
├── c_api/local_agent_inference.cpp
├── core/
│   ├── inference_engine.h
│   ├── model_config.h
│   ├── model_config.cpp
│   ├── token_event.h
│   ├── token_stream.h
│   └── token_stream.cpp
├── backends/
│   ├── mock/
│   │   ├── mock_inference_engine.h
│   │   └── mock_inference_engine.cpp
│   └── llama_cpp/
│       ├── llama_cpp_api.h
│       ├── llama_cpp_api.cpp
│       ├── llama_cpp_engine.h
│       ├── llama_cpp_engine.cpp
│       ├── llama_cpp_prompt.h
│       └── llama_cpp_prompt.cpp
└── tests/
    ├── c_api_backend_contract.cpp
    ├── header_contract.c
    ├── llama_cpp_backend_contract.cpp
    ├── llama_cpp_prompt_contract.cpp
    ├── mock_backend_contract.cpp
    ├── model_config_contract.cpp
    └── token_stream_contract.cpp
```

Existing Rust local inference bridge, retained until later Swift/Rust bridge takeover:

```text
local-ios-agent/rust-core/build.rs
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/scripts/build-local-inference-simulator.sh
local-ios-agent/scripts/build-llama-cpp-xcframework.sh
local-ios-agent/scripts/build-llama-cpp-mtmd-ios-simulator.sh
```

Target local inference files after this plan:

```text
local-ios-agent/inference/
├── include/local_agent_inference.h
├── c_api/
│   └── local_agent_inference.cpp
├── core/
│   ├── engine_capabilities.h
│   ├── engine_registry.h
│   ├── engine_registry.cpp
│   ├── generation_request.h
│   ├── generation_request.cpp
│   ├── generation_session.h
│   ├── inference_engine.h
│   ├── json_value.h
│   ├── json_value.cpp
│   ├── loaded_model.h
│   ├── model_config.h
│   ├── model_config.cpp
│   ├── token_event.h
│   ├── token_stream.h
│   └── token_stream.cpp
├── backends/
│   ├── mock/
│   ├── llama_cpp/
│   └── litert/
│       ├── litert_engine.h
│       └── litert_engine.cpp
└── tests/
    ├── c_api_release_registry_contract.cpp
    ├── c_api_v2_contract.cpp
    ├── engine_registry_contract.cpp
    ├── generation_request_contract.cpp
    ├── header_contract.c
    ├── json_value_contract.cpp
    ├── llama_cpp_backend_contract.cpp
    ├── llama_cpp_prompt_contract.cpp
    ├── mock_backend_contract.cpp
    ├── model_config_contract.cpp
    └── token_stream_contract.cpp
```

## Task 1: Add A v2 C++ Contract Test Runner

- [ ] Create `local-ios-agent/scripts/run-local-inference-cpp-contracts.sh`.
- [ ] Make it compile and run only C++ core/backend contracts that remain valid for the v2 refactor.
- [ ] Do not run `c_api_backend_contract.cpp`; that test belongs to the old v1 ABI and is removed in Task 2.
- [ ] Do not run the current `mock_backend_contract.cpp`; it also exercises the old v1 C ABI and is rewritten as a core mock contract in Task 6.
- [ ] Use `LOCAL_AGENT_ENABLE_TEST_ENGINES` in this script so mock is available only in contract builds.

Script content:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${LOCAL_AGENT_CPP_TEST_BUILD_DIR:-/tmp/local-agent-inference-contracts}"
CC_BIN="${CC:-clang}"
CXX_BIN="${CXX:-clang++}"

mkdir -p "$BUILD_DIR"
cd "$ROOT"

CXXFLAGS=(
  -std=c++17
  -DLOCAL_AGENT_ENABLE_TEST_ENGINES
  -I inference/include
  -I inference/core
  -I inference/backends/mock
  -I inference/backends/llama_cpp
  -I inference/backends/litert
)

"$CC_BIN" -std=c11 -I inference/include \
  -c inference/tests/header_contract.c \
  -o "$BUILD_DIR/header_contract.o"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/token_stream_contract.cpp \
  inference/core/token_stream.cpp \
  -o "$BUILD_DIR/token_stream_contract"
"$BUILD_DIR/token_stream_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/model_config_contract.cpp \
  inference/core/model_config.cpp \
  -o "$BUILD_DIR/model_config_contract"
"$BUILD_DIR/model_config_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/llama_cpp_backend_contract.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/llama_cpp/llama_cpp_api.cpp \
  inference/backends/llama_cpp/llama_cpp_engine.cpp \
  inference/backends/llama_cpp/llama_cpp_prompt.cpp \
  -o "$BUILD_DIR/llama_cpp_backend_contract"
if "$BUILD_DIR/llama_cpp_backend_contract"; then
  :
else
  status=$?
  if [[ "$status" != "77" ]]; then
    exit "$status"
  fi
fi

echo "local inference C++ contracts passed"
```

Verification command:

```bash
chmod +x local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "test: add local inference cpp contract runner"
```

## Task 2: Replace v1 Public ABI With v2 Header Declarations

- [ ] Remove v1 `local_agent_backend_*` function declarations from `local-ios-agent/inference/include/local_agent_inference.h`.
- [ ] Extend `local-ios-agent/inference/include/local_agent_inference.h` with v2 opaque handles and function declarations.
- [ ] Rewrite `local-ios-agent/inference/tests/header_contract.c` so a C compiler sees only the v2 public ABI.
- [ ] Delete `local-ios-agent/inference/tests/c_api_backend_contract.cpp`.
- [ ] Keep this task compile-only. Runtime/link behavior is covered when Task 7 implements v2.

Header additions:

```c
typedef struct LocalAgentEngineHandle LocalAgentEngineHandle;
typedef struct LocalAgentModelHandle LocalAgentModelHandle;
typedef struct LocalAgentGenerationHandle LocalAgentGenerationHandle;

typedef struct LocalAgentImageInput {
    const uint8_t *bytes;
    uint64_t byte_count;
    uint32_t width;
    uint32_t height;
    const char *pixel_format;
} LocalAgentImageInput;

void local_agent_string_free(char *value);

LocalAgentStatus local_agent_engine_list(char **out_json);
LocalAgentStatus local_agent_engine_create(
    const char *engine_id,
    LocalAgentEngineHandle **out_engine
);
LocalAgentStatus local_agent_engine_capabilities(
    LocalAgentEngineHandle *engine,
    char **out_json
);
LocalAgentStatus local_agent_engine_release(LocalAgentEngineHandle *engine);

LocalAgentStatus local_agent_model_load(
    LocalAgentEngineHandle *engine,
    const char *model_config_json,
    LocalAgentModelHandle **out_model
);
LocalAgentStatus local_agent_model_unload(LocalAgentModelHandle *model);

LocalAgentStatus local_agent_generation_start(
    LocalAgentModelHandle *model,
    const char *generation_request_json,
    const LocalAgentImageInput *images,
    uint64_t image_count,
    LocalAgentGenerationHandle **out_generation
);
LocalAgentStatus local_agent_generation_read(
    LocalAgentGenerationHandle *generation,
    local_agent_token_callback callback,
    void *user_data
);
LocalAgentStatus local_agent_generation_cancel(LocalAgentGenerationHandle *generation);
LocalAgentStatus local_agent_generation_release(LocalAgentGenerationHandle *generation);

LocalAgentStatus local_agent_last_error(
    LocalAgentEngineHandle *engine,
    char **out_json
);
```

`header_contract.c` must contain only v2 API references:

```c
#include "local_agent_inference.h"

static LocalAgentStatus collect_token(const char *token_json, void *user_data) {
    (void)token_json;
    (void)user_data;
    return LOCAL_AGENT_STATUS_OK;
}

int main(void) {
LocalAgentStatus status = LOCAL_AGENT_STATUS_OK;
local_agent_token_callback callback = collect_token;
char *json = 0;
LocalAgentImageInput image = {0};
LocalAgentEngineHandle *engine = 0;
LocalAgentModelHandle *model = 0;
LocalAgentGenerationHandle *generation = 0;

status = local_agent_engine_list(&json);
local_agent_string_free(json);
status = local_agent_engine_create("mock", &engine);
status = local_agent_engine_capabilities(engine, &json);
local_agent_string_free(json);
status = local_agent_model_load(engine, "{\"engine\":\"mock\",\"model_path\":\"/tmp/mock.gguf\"}", &model);
status = local_agent_generation_start(model, "{\"messages\":[]}", &image, 0, &generation);
status = local_agent_generation_read(generation, callback, 0);
status = local_agent_generation_cancel(generation);
status = local_agent_generation_release(generation);
status = local_agent_model_unload(model);
status = local_agent_last_error(engine, &json);
local_agent_string_free(json);
status = local_agent_engine_release(engine);
return (int)status;
}
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/include/local_agent_inference.h \
  local-ios-agent/inference/tests/header_contract.c \
  local-ios-agent/inference/tests/c_api_backend_contract.cpp \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "refactor: replace local inference c abi with v2 declarations"
```

## Task 3: Add Error And String Ownership Primitives

- [ ] Add stable local error primitives inside `local-ios-agent/inference/c_api/local_agent_inference.cpp`.
- [ ] Implement `local_agent_string_free`.
- [ ] Add stable error JSON generation and thread-local fallback error for calls that happen before an engine handle exists.

Core C ABI implementation shape:

```cpp
namespace local_agent {

enum class LocalAgentErrorCode {
    invalid_argument,
    engine_unavailable,
    unsupported_model_format,
    model_file_missing,
    model_load_failed,
    context_too_large,
    vision_not_supported,
    generation_cancelled,
    generation_failed,
    stream_interrupted,
    usage_unavailable,
    internal_error,
};

struct LocalAgentError {
    LocalAgentErrorCode code = LocalAgentErrorCode::internal_error;
    std::string message;
    std::string engine;
    bool recoverable = false;
};

} // namespace local_agent
```

C API implementation rules:

```cpp
void local_agent_string_free(char *value) {
    delete[] value;
}
```

`copy_c_string` must allocate with `new char[size + 1]`, copy the null terminator, and always return a non-null pointer for valid output strings.

`local_agent_last_error(engine, &out_json)` must:

```text
return INVALID_ARGUMENT when out_json is null
set *out_json to null before work
use the engine handle's last error when engine is not null
use thread_last_error() when engine is null
return OK when JSON allocation succeeds
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected result after only this task:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/c_api/local_agent_inference.cpp \
  local-ios-agent/inference/include/local_agent_inference.h
git commit -m "feat: add local inference error and string ownership primitives"
```

## Task 4: Add Engine Capabilities And Registry

- [ ] Add `local-ios-agent/inference/core/engine_capabilities.h`.
- [ ] Add `local-ios-agent/inference/core/engine_registry.h`.
- [ ] Add `local-ios-agent/inference/core/engine_registry.cpp`.
- [ ] Add `local-ios-agent/inference/tests/engine_registry_contract.cpp`.
- [ ] Update the C++ contract runner source lists to include the new core files.

Core descriptors:

```cpp
namespace local_agent {

struct EngineCapabilities {
    bool supports_vision = false;
    bool supports_streaming = true;
    bool supports_cancellation = true;
    bool supports_token_usage = false;
    int max_context_tokens = 0;
    std::vector<std::string> supported_model_formats;
};

struct EngineDescriptor {
    std::string engine_id;
    std::string display_name;
    EngineCapabilities capabilities;
    bool test_only = false;
};

std::string engine_descriptor_list_json(const std::vector<EngineDescriptor> &descriptors);
std::string engine_capabilities_json(const EngineDescriptor &descriptor);

class EngineRegistry {
public:
    static EngineRegistry production();
    static EngineRegistry test();

    std::vector<EngineDescriptor> list() const;
    const EngineDescriptor *find(const std::string &engine_id) const;
    std::unique_ptr<InferenceEngine> create(const std::string &engine_id) const;

private:
    std::vector<EngineDescriptor> descriptors_;
};

} // namespace local_agent
```

Registry behavior:

```text
LOCAL_AGENT_ENABLE_TEST_ENGINES registers mock with test_only=true.
LOCAL_AGENT_ENABLE_LLAMA_CPP registers llama_cpp.
LOCAL_AGENT_ENABLE_LITERT plus LOCAL_AGENT_ENABLE_LITERT_VENDOR registers litert in vendor-linked builds.
LOCAL_AGENT_ENABLE_LITERT alone does not register litert.
production() never registers mock.
test() registers mock when LOCAL_AGENT_ENABLE_TEST_ENGINES is defined.
create("mock") fails unless mock was registered.
```

`engine_registry_contract.cpp` must assert:

```cpp
auto test_registry = local_agent::EngineRegistry::test();
auto test_descriptors = test_registry.list();
assert(std::any_of(test_descriptors.begin(), test_descriptors.end(), [](const auto &descriptor) {
    return descriptor.engine_id == "mock" && descriptor.test_only;
}));

auto production_registry = local_agent::EngineRegistry::production();
auto production_descriptors = production_registry.list();
assert(std::none_of(production_descriptors.begin(), production_descriptors.end(), [](const auto &descriptor) {
    return descriptor.engine_id == "mock";
}));

const auto *mock = test_registry.find("mock");
assert(mock != nullptr);
assert(mock->capabilities.supports_streaming);
assert(!mock->capabilities.supported_model_formats.empty());
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/core/engine_capabilities.h \
  local-ios-agent/inference/core/engine_registry.h \
  local-ios-agent/inference/core/engine_registry.cpp \
  local-ios-agent/inference/tests/engine_registry_contract.cpp \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "feat: add local inference engine registry"
```

## Task 5: Add JSON Parser And Split Model Load Config From Generation Request

- [ ] Add `local-ios-agent/inference/core/json_value.h`.
- [ ] Add `local-ios-agent/inference/core/json_value.cpp`.
- [ ] Add `local-ios-agent/inference/tests/json_value_contract.cpp`.
- [ ] Update `local-ios-agent/inference/core/model_config.h` and `.cpp`.
- [ ] Add `local-ios-agent/inference/core/generation_request.h`.
- [ ] Add `local-ios-agent/inference/core/generation_request.cpp`.
- [ ] Add `local-ios-agent/inference/tests/generation_request_contract.cpp`.
- [ ] Replace `find_raw_value` usage for new v2 parsing. Do not extend string-scanning JSON parsing for nested v2 objects.
- [ ] Update `local-ios-agent/scripts/run-local-inference-cpp-contracts.sh` to compile `json_value_contract.cpp` and `generation_request_contract.cpp`.

JSON parser target:

```cpp
namespace local_agent::json {

class Value {
public:
    enum class Type { null_value, bool_value, number_value, string_value, array_value, object_value };

    Type type() const;
    bool is_object() const;
    bool is_array() const;
    const std::string &as_string() const;
    double as_number() const;
    bool as_bool() const;
    const std::vector<Value> &as_array() const;
    const std::map<std::string, Value> &as_object() const;
    const Value *get(const std::string &key) const;
};

Value parse(const char *json);
std::string require_string(const Value &object, const std::string &key);
std::string optional_string(const Value &object, const std::string &key, const std::string &fallback);
int optional_int(const Value &object, const std::string &key, int fallback);
float optional_float(const Value &object, const std::string &key, float fallback);

} // namespace local_agent::json
```

Parser scope:

```text
Support JSON objects, arrays, strings, numbers, booleans, and null.
Support escaped strings for at least \", \\, \n, \r, \t.
Reject malformed JSON with std::invalid_argument.
Reject trailing non-whitespace after a valid JSON value.
Do not depend on Foundation, Swift, Rust, or vendor inference libraries.
```

`json_value_contract.cpp` must assert:

```cpp
auto value = local_agent::json::parse(R"({
  "messages":[{"role":"user","content":"hello \"Alex\"\nnext"}],
  "sampling":{"temperature":0.2,"max_new_tokens":32},
  "enabled":true
})");

assert(value.is_object());
const auto *messages = value.get("messages");
assert(messages != nullptr);
assert(messages->is_array());
const auto &first = messages->as_array().at(0);
assert(local_agent::json::require_string(first, "role") == "user");
assert(local_agent::json::require_string(first, "content") == "hello \"Alex\"\nnext");

const auto *sampling = value.get("sampling");
assert(sampling != nullptr);
assert(local_agent::json::optional_float(*sampling, "temperature", 1.0f) == 0.2f);
assert(local_agent::json::optional_int(*sampling, "max_new_tokens", 0) == 32);

bool rejected_bad_json = false;
try {
    local_agent::json::parse(R"({"messages":[})");
} catch (const std::invalid_argument &) {
    rejected_bad_json = true;
}
assert(rejected_bad_json);
```

Runner additions:

```bash
COMMON_SOURCES=(
  inference/c_api/local_agent_inference.cpp
  inference/core/json_value.cpp
  inference/core/model_config.cpp
  inference/core/generation_request.cpp
  inference/core/token_stream.cpp
  inference/backends/mock/mock_inference_engine.cpp
  inference/backends/llama_cpp/llama_cpp_api.cpp
  inference/backends/llama_cpp/llama_cpp_engine.cpp
  inference/backends/llama_cpp/llama_cpp_prompt.cpp
)

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/model_config_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/model_config.cpp \
  -o "$BUILD_DIR/model_config_contract"
"$BUILD_DIR/model_config_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/json_value_contract.cpp \
  inference/core/json_value.cpp \
  -o "$BUILD_DIR/json_value_contract"
"$BUILD_DIR/json_value_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/generation_request_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/generation_request.cpp \
  -o "$BUILD_DIR/generation_request_contract"
"$BUILD_DIR/generation_request_contract"
```

Model config target:

```cpp
struct RuntimeOptions {
    int n_gpu_layers = 0;
    int n_threads = 4;
};

struct ModelLoadConfig {
    std::string engine;
    std::string model_id;
    std::string model_format;
    std::string model_path;
    std::string mmproj_path;
    std::string chat_template;
    int context_tokens = 2048;
    RuntimeOptions runtime;
};

ModelLoadConfig parse_model_load_config(const char *model_config_json);
```

Model load parsing rules:

```text
parse_model_load_config requires "engine".
Do not accept legacy "backend".
model_path is required.
model_format defaults to "mock" for mock and "gguf" for llama_cpp.
context_tokens is read from "context_tokens".
runtime.n_threads is read from nested "runtime.n_threads".
runtime.n_gpu_layers is read from nested "runtime.n_gpu_layers".
```

Generation request target:

```cpp
struct SamplingConfig {
    float temperature = 0.2f;
    float top_p = 0.9f;
    int top_k = 40;
    float min_p = 0.05f;
    float repeat_penalty = 1.1f;
    int seed = 42;
    int max_new_tokens = 128;
    std::vector<std::string> stop_sequences;
};

struct PromptMessage {
    std::string role;
    std::string content;
};

struct ImageMetadata {
    std::string format;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct GenerationRequest {
    std::vector<PromptMessage> messages;
    std::vector<ImageMetadata> images;
    SamplingConfig sampling;
};

GenerationRequest parse_generation_request(const char *generation_request_json);
std::string prompt_json_from_generation_request(const GenerationRequest &request);
```

`generation_request_contract.cpp` must assert:

```cpp
auto request = local_agent::parse_generation_request(R"({
  "messages":[
    {"role":"system","content":"You are concise."},
    {"role":"user","content":"hello"}
  ],
  "images":[{"format":"rgb8","width":1,"height":1}],
  "sampling":{"temperature":0.1,"top_p":0.8,"max_new_tokens":16,"seed":7}
})");

assert(request.messages.size() == 2);
assert(request.messages[1].role == "user");
assert(request.messages[1].content == "hello");
assert(request.images.size() == 1);
assert(request.images[0].format == "rgb8");
assert(request.sampling.temperature == 0.1f);
assert(request.sampling.max_new_tokens == 16);

bool rejected_empty_messages = false;
try {
    local_agent::parse_generation_request(R"({"messages":[]})");
} catch (const std::exception &) {
    rejected_empty_messages = true;
}
assert(rejected_empty_messages);
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/core/model_config.h \
  local-ios-agent/inference/core/model_config.cpp \
  local-ios-agent/inference/core/json_value.h \
  local-ios-agent/inference/core/json_value.cpp \
  local-ios-agent/inference/core/generation_request.h \
  local-ios-agent/inference/core/generation_request.cpp \
  local-ios-agent/inference/tests/json_value_contract.cpp \
  local-ios-agent/inference/tests/model_config_contract.cpp \
  local-ios-agent/inference/tests/generation_request_contract.cpp \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "feat: split local model load config from generation request"
```

## Task 6: Add LoadedModel And GenerationSession Interfaces

- [ ] Add `local-ios-agent/inference/core/loaded_model.h`.
- [ ] Add `local-ios-agent/inference/core/generation_session.h`.
- [ ] Update `local-ios-agent/inference/core/inference_engine.h`.
- [ ] Adapt mock and llama.cpp engines to the new internal shape.
- [ ] Remove v1 facade assumptions from backend tests and keep all stream assertions aligned with v2 events.

Core interfaces:

```cpp
namespace local_agent {

struct UsageReport {
    int prompt_tokens = 0;
    int completion_tokens = 0;
    int total_tokens = 0;
    bool available = false;
};

struct ModelRuntimeInfo {
    std::string engine_id;
    std::string model_id;
    int context_tokens = 0;
    bool vision_enabled = false;
};

struct ImageInput {
    std::vector<unsigned char> rgb_data;
    uint32_t width = 0;
    uint32_t height = 0;
};

class GenerationSession {
public:
    virtual ~GenerationSession() = default;
    virtual void read(const TokenStream::Emit &emit) = 0;
    virtual void cancel() = 0;
    virtual UsageReport usage() const = 0;
};

class LoadedModel {
public:
    virtual ~LoadedModel() = default;
    virtual ModelRuntimeInfo runtime_info() const = 0;
    virtual std::unique_ptr<GenerationSession> start_generation(
        const GenerationRequest &request,
        const std::vector<ImageInput> &images
    ) = 0;
};

class InferenceEngine {
public:
    virtual ~InferenceEngine() = default;
    virtual EngineCapabilities capabilities() const = 0;
    virtual std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) = 0;
};

} // namespace local_agent
```

Mock adapter behavior:

```text
MockInferenceEngine::load_model validates model_path and returns MockLoadedModel.
MockLoadedModel::start_generation validates messages and returns MockGenerationSession.
MockGenerationSession::read emits:
  text_delta "On-device "
  text_delta "mock response"
  usage with deterministic counts
  completed "On-device mock response"
The usage event is visible through v2 generation reads and core session tests.
```

llama.cpp adapter behavior:

```text
LlamaCppEngine::load_model validates engine/model_format and returns LlamaCppLoadedModel.
LlamaCppLoadedModel owns LlamaCppSession and ModelConfig.
LlamaCppGenerationSession owns prompt_json, copied images, cancellation state, and usage.
No request-scoped prompt/image state remains on LlamaCppEngine.
```

Update `token_stream_contract.cpp` to expect usage support:

```cpp
stream.emit_usage({1, 2, 3, true}, [&](const std::string &json) {
    tokens.push_back(json);
    return true;
});
assert(tokens.back() == R"({"type":"usage","prompt_tokens":1,"completion_tokens":2,"total_tokens":3})");
```

Rewrite `mock_backend_contract.cpp` as a core backend test:

```cpp
#include "generation_request.h"
#include "mock_inference_engine.h"

#include <cassert>
#include <string>
#include <vector>

int main() {
    local_agent::ModelLoadConfig config;
    config.engine = "mock";
    config.model_id = "mock.local";
    config.model_format = "mock";
    config.model_path = "/tmp/mock.gguf";
    config.context_tokens = 128;

    local_agent::MockInferenceEngine engine;
    auto model = engine.load_model(config);
    assert(model != nullptr);
    assert(model->runtime_info().engine_id == "mock");

    auto request = local_agent::parse_generation_request(
        R"({"messages":[{"role":"user","content":"hello"}],"sampling":{"max_new_tokens":8}})"
    );
    auto generation = model->start_generation(request, {});

    std::vector<std::string> events;
    generation->read([&](const std::string &event) {
        events.push_back(event);
        return true;
    });

    assert(events.size() == 4);
    assert(events[0] == R"({"type":"text_delta","text":"On-device "})");
    assert(events[1] == R"({"type":"text_delta","text":"mock response"})");
    assert(events[2].find("\"type\":\"usage\"") != std::string::npos);
    assert(events[3] == R"({"type":"completed","text":"On-device mock response"})");
    return 0;
}
```

Runner addition:

```bash
"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/mock_backend_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/model_config.cpp \
  inference/core/generation_request.cpp \
  inference/core/token_stream.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o "$BUILD_DIR/mock_backend_contract"
"$BUILD_DIR/mock_backend_contract"
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/core/inference_engine.h \
  local-ios-agent/inference/core/loaded_model.h \
  local-ios-agent/inference/core/generation_session.h \
  local-ios-agent/inference/core/token_stream.h \
  local-ios-agent/inference/core/token_stream.cpp \
  local-ios-agent/inference/backends/mock/mock_inference_engine.h \
  local-ios-agent/inference/backends/mock/mock_inference_engine.cpp \
  local-ios-agent/inference/backends/llama_cpp/llama_cpp_engine.h \
  local-ios-agent/inference/backends/llama_cpp/llama_cpp_engine.cpp \
  local-ios-agent/inference/tests/token_stream_contract.cpp \
  local-ios-agent/inference/tests/mock_backend_contract.cpp \
  local-ios-agent/inference/tests/llama_cpp_backend_contract.cpp
git commit -m "feat: split loaded model and generation session"
```

## Task 7: Implement v2 C ABI Handles

- [ ] Create `local-ios-agent/inference/tests/c_api_v2_contract.cpp`.
- [ ] Implement `LocalAgentEngineHandle`, `LocalAgentModelHandle`, and `LocalAgentGenerationHandle` in `local-ios-agent/inference/c_api/local_agent_inference.cpp`.
- [ ] Implement all v2 C ABI functions declared in Task 2.
- [ ] Store last error on engine handles and thread-local fallback.
- [ ] Release functions must tolerate null and return `LOCAL_AGENT_STATUS_OK`.
- [ ] Use shared internal state so releasing an engine before its models, or a model before its generations, does not leave child handles with dangling parent pointers.
- [ ] Add out-of-order release coverage to `c_api_v2_contract.cpp`.
- [ ] Add `local-ios-agent/inference/tests/c_api_release_registry_contract.cpp`.
- [ ] Add a release-like runner section that omits `LOCAL_AGENT_ENABLE_TEST_ENGINES` and verifies the public ABI does not expose `mock`.

Handle shape:

```cpp
struct LocalAgentEngineState {
    std::string engine_id;
    local_agent::EngineDescriptor descriptor;
    std::unique_ptr<local_agent::InferenceEngine> engine;
    local_agent::LocalAgentError last_error;
};

struct LocalAgentModelState {
    std::shared_ptr<LocalAgentEngineState> engine_state;
    std::unique_ptr<local_agent::LoadedModel> model;
    local_agent::ModelRuntimeInfo runtime_info;
};

struct LocalAgentGenerationState {
    std::shared_ptr<LocalAgentModelState> model_state;
    std::unique_ptr<local_agent::GenerationSession> generation;
    local_agent::TokenStream stream;
};

struct LocalAgentEngineHandle {
    std::shared_ptr<LocalAgentEngineState> state;
};

struct LocalAgentModelHandle {
    std::shared_ptr<LocalAgentModelState> state;
};

struct LocalAgentGenerationHandle {
    std::shared_ptr<LocalAgentGenerationState> state;
};
```

Implementation rules:

```text
Every out pointer is set to null before work.
Every function validates required input pointers.
Exceptions become LocalAgentError and stable LocalAgentStatus.
local_agent_engine_list uses EngineRegistry::test when LOCAL_AGENT_ENABLE_TEST_ENGINES is defined, otherwise EngineRegistry::production.
local_agent_engine_create fails with engine_unavailable when the engine id is absent.
local_agent_model_load parses ModelLoadConfig and validates config.engine matches the engine handle id.
local_agent_generation_read maps callback cancellation to LOCAL_AGENT_STATUS_CANCELLED.
Releasing a parent handle decreases the caller's reference only; child handles keep shared state alive.
Passing the exact same already-released raw handle pointer a second time is invalid; Swift wrappers must nil out pointers after release.
```

Create `c_api_v2_contract.cpp` with the base lifecycle contract:

```cpp
#include "local_agent_inference.h"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

static LocalAgentStatus collect_token(const char *token_json, void *user_data) {
    auto *events = static_cast<std::vector<std::string> *>(user_data);
    events->emplace_back(token_json);
    return LOCAL_AGENT_STATUS_OK;
}

int main() {
    char *engine_list_json = nullptr;
    assert(local_agent_engine_list(&engine_list_json) == LOCAL_AGENT_STATUS_OK);
    assert(engine_list_json != nullptr);
    std::string engine_list(engine_list_json);
    assert(engine_list.find("\"engine_id\":\"mock\"") != std::string::npos);
    local_agent_string_free(engine_list_json);

    LocalAgentEngineHandle *engine = nullptr;
    assert(local_agent_engine_create("mock", &engine) == LOCAL_AGENT_STATUS_OK);
    assert(engine != nullptr);

    char *capabilities_json = nullptr;
    assert(local_agent_engine_capabilities(engine, &capabilities_json) == LOCAL_AGENT_STATUS_OK);
    assert(std::string(capabilities_json).find("\"supports_streaming\":true") != std::string::npos);
    local_agent_string_free(capabilities_json);

    LocalAgentModelHandle *model = nullptr;
    assert(local_agent_model_load(
        engine,
        R"({"engine":"mock","model_id":"mock.local","model_path":"/tmp/mock.gguf","model_format":"mock"})",
        &model
    ) == LOCAL_AGENT_STATUS_OK);

    LocalAgentGenerationHandle *generation = nullptr;
    assert(local_agent_generation_start(
        model,
        R"({"messages":[{"role":"user","content":"hello"}],"sampling":{"max_new_tokens":8}})",
        nullptr,
        0,
        &generation
    ) == LOCAL_AGENT_STATUS_OK);
    assert(generation != nullptr);

    std::vector<std::string> events;
    assert(local_agent_generation_read(generation, collect_token, &events) == LOCAL_AGENT_STATUS_OK);
    assert(events.front().find("\"type\":\"text_delta\"") != std::string::npos);
    assert(std::any_of(events.begin(), events.end(), [](const std::string &event) {
        return event.find("\"type\":\"usage\"") != std::string::npos;
    }));
    assert(events.back().find("\"type\":\"completed\"") != std::string::npos);

    assert(local_agent_generation_release(generation) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_model_unload(model) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_engine_release(engine) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_generation_release(nullptr) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_model_unload(nullptr) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_engine_release(nullptr) == LOCAL_AGENT_STATUS_OK);

    return 0;
}
```

Extend `c_api_v2_contract.cpp` with a negative path:

```cpp
LocalAgentEngineHandle *missing = nullptr;
assert(local_agent_engine_create("missing_engine", &missing) == LOCAL_AGENT_STATUS_ERROR);
assert(missing == nullptr);

char *error_json = nullptr;
assert(local_agent_last_error(nullptr, &error_json) == LOCAL_AGENT_STATUS_OK);
assert(std::string(error_json).find("\"code\":\"engine_unavailable\"") != std::string::npos);
local_agent_string_free(error_json);
```

Extend `c_api_v2_contract.cpp` with out-of-order release:

```cpp
LocalAgentEngineHandle *parent_engine = nullptr;
assert(local_agent_engine_create("mock", &parent_engine) == LOCAL_AGENT_STATUS_OK);

LocalAgentModelHandle *child_model = nullptr;
assert(local_agent_model_load(
    parent_engine,
    R"({"engine":"mock","model_id":"mock.parent","model_path":"/tmp/mock.gguf","model_format":"mock"})",
    &child_model
) == LOCAL_AGENT_STATUS_OK);

LocalAgentGenerationHandle *child_generation = nullptr;
assert(local_agent_generation_start(
    child_model,
    R"({"messages":[{"role":"user","content":"release order"}]})",
    nullptr,
    0,
    &child_generation
) == LOCAL_AGENT_STATUS_OK);

assert(local_agent_engine_release(parent_engine) == LOCAL_AGENT_STATUS_OK);
assert(local_agent_model_unload(child_model) == LOCAL_AGENT_STATUS_OK);

std::vector<std::string> out_of_order_events;
assert(local_agent_generation_read(
    child_generation,
    collect_token,
    &out_of_order_events
) == LOCAL_AGENT_STATUS_OK);
assert(!out_of_order_events.empty());
assert(local_agent_generation_release(child_generation) == LOCAL_AGENT_STATUS_OK);
```

Update the runner to compile and run the v2 contract in this task:

```bash
"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/c_api_v2_contract.cpp \
  "${COMMON_SOURCES[@]}" \
  -o "$BUILD_DIR/c_api_v2_contract"
"$BUILD_DIR/c_api_v2_contract"
```

`c_api_release_registry_contract.cpp` must assert through the public ABI:

```cpp
#include "local_agent_inference.h"

#include <cassert>
#include <string>

int main() {
    char *engine_list_json = nullptr;
    assert(local_agent_engine_list(&engine_list_json) == LOCAL_AGENT_STATUS_OK);
    assert(engine_list_json != nullptr);
    std::string engine_list(engine_list_json);
    local_agent_string_free(engine_list_json);

    assert(engine_list.find("\"engine_id\":\"mock\"") == std::string::npos);
    return 0;
}
```

Release-like runner section:

```bash
RELEASE_CXXFLAGS=(
  -std=c++17
  -I inference/include
  -I inference/core
  -I inference/backends/mock
  -I inference/backends/llama_cpp
  -I inference/backends/litert
)

"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  inference/tests/c_api_release_registry_contract.cpp \
  "${COMMON_SOURCES[@]}" \
  -o "$BUILD_DIR/c_api_release_registry_contract"
"$BUILD_DIR/c_api_release_registry_contract"
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/c_api/local_agent_inference.cpp \
  local-ios-agent/inference/include/local_agent_inference.h \
  local-ios-agent/inference/tests/c_api_v2_contract.cpp \
  local-ios-agent/inference/tests/c_api_release_registry_contract.cpp \
  local-ios-agent/inference/tests/header_contract.c \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "feat: add v2 local inference c abi handles"
```

## Task 8: Add v2 Multimodal Buffer Contract

- [ ] Implement `LocalAgentImageInput` conversion in `local_agent_generation_start`.
- [ ] Accept only `pixel_format == "rgb8"` in the first v2 implementation.
- [ ] Validate `byte_count == width * height * 3`.
- [ ] Copy bytes into `std::vector<unsigned char>` before returning.
- [ ] Add a deterministic mock image contract.

Conversion helper:

```cpp
std::vector<local_agent::ImageInput> copy_image_inputs(
    const LocalAgentImageInput *images,
    uint64_t image_count
) {
    std::vector<local_agent::ImageInput> copied;
    if (image_count == 0) {
        return copied;
    }
    if (images == nullptr) {
        throw std::invalid_argument("image_count requires image input array");
    }
    copied.reserve(static_cast<size_t>(image_count));
    for (uint64_t index = 0; index < image_count; index += 1) {
        const auto &image = images[index];
        if (image.bytes == nullptr || image.pixel_format == nullptr) {
            throw std::invalid_argument("image input requires bytes and pixel_format");
        }
        if (std::string(image.pixel_format) != "rgb8") {
            throw std::invalid_argument("only rgb8 image input is supported");
        }
        const uint64_t expected = static_cast<uint64_t>(image.width) *
            static_cast<uint64_t>(image.height) * 3;
        if (image.width == 0 || image.height == 0 || image.byte_count != expected) {
            throw std::invalid_argument("rgb8 image byte_count does not match dimensions");
        }
        local_agent::ImageInput copied_image;
        copied_image.width = image.width;
        copied_image.height = image.height;
        copied_image.rgb_data.assign(image.bytes, image.bytes + image.byte_count);
        copied.push_back(std::move(copied_image));
    }
    return copied;
}
```

Extend `c_api_v2_contract.cpp` with copy semantics:

```cpp
uint8_t pixel[3] = {255, 128, 64};
LocalAgentImageInput image = {
    pixel,
    3,
    1,
    1,
    "rgb8"
};

LocalAgentGenerationHandle *image_generation = nullptr;
assert(local_agent_generation_start(
    model,
    R"({"messages":[{"role":"user","content":"describe"}],"images":[{"format":"rgb8","width":1,"height":1}]})",
    &image,
    1,
    &image_generation
) == LOCAL_AGENT_STATUS_OK);
pixel[0] = 0;

std::vector<std::string> image_events;
assert(local_agent_generation_read(image_generation, collect_token, &image_events) == LOCAL_AGENT_STATUS_OK);
assert(std::any_of(image_events.begin(), image_events.end(), [](const std::string &event) {
    return event.find("image_rgb_first_byte=255") != std::string::npos;
}));
assert(local_agent_generation_release(image_generation) == LOCAL_AGENT_STATUS_OK);
```

Mock image behavior:

```text
When images are present, the mock generation emits a structured_delta containing
"image_rgb_first_byte=255" for the first copied byte.
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/c_api/local_agent_inference.cpp \
  local-ios-agent/inference/backends/mock/mock_inference_engine.cpp \
  local-ios-agent/inference/tests/c_api_v2_contract.cpp
git commit -m "feat: add local inference v2 image buffer contract"
```

## Task 9: Remove Legacy Local Inference Entry Points

- [ ] Remove v1 `LocalAgentBackend` and `LocalAgentBackendStream` implementation state from `local-ios-agent/inference/c_api/local_agent_inference.cpp`.
- [ ] Remove all `local_agent_backend_*` function definitions from `local-ios-agent/inference/c_api/local_agent_inference.cpp`.
- [ ] Remove old v1 C ABI tests from the contract runner and repository.

Removal rules:

```text
The public C header no longer declares local_agent_backend_*.
The C API implementation no longer defines local_agent_backend_*.
The contract runner no longer compiles c_api_backend_contract.cpp.
Swift will adopt v2 through a later LocalCppInferenceClient.
```

Verification commands:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
rg -n "local_agent_backend_|LocalAgentBackend" local-ios-agent/inference
```

Expected output:

```text
local inference C++ contracts passed
rg has no matches
```

Commit:

```bash
git add local-ios-agent/inference/c_api/local_agent_inference.cpp \
  local-ios-agent/inference/include/local_agent_inference.h \
  local-ios-agent/inference/tests/c_api_backend_contract.cpp \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "refactor: remove legacy local inference entry points"
```

## Task 10: Add LiteRT Adapter Boundary Behind Vendor Gate

- [ ] Add `local-ios-agent/inference/backends/litert/litert_engine.h`.
- [ ] Add `local-ios-agent/inference/backends/litert/litert_engine.cpp`.
- [ ] Add `local-ios-agent/inference/backends/litert/litert_api.h/.cpp` as the adapter session boundary.
- [ ] Compile adapter-boundary tests with an injected test `LiteRTSession`.
- [ ] Register public `litert` only when `LOCAL_AGENT_ENABLE_LITERT` and `LOCAL_AGENT_ENABLE_LITERT_VENDOR` are both defined by a build that also links the vendor runtime bridge.
- [ ] Add registry tests proving `litert` is absent with no LiteRT macro and also absent when only `LOCAL_AGENT_ENABLE_LITERT` is defined.

Adapter boundary:

```cpp
namespace local_agent {

class LiteRTSession;

class LiteRTInferenceEngine final : public InferenceEngine {
public:
    LiteRTInferenceEngine();
    explicit LiteRTInferenceEngine(std::unique_ptr<LiteRTSession> session);

    EngineCapabilities capabilities() const override;
    std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &config) override;
};

} // namespace local_agent
```

Registry behavior:

```text
Without LOCAL_AGENT_ENABLE_LITERT:
  litert is not registered and not user-selectable.

With LOCAL_AGENT_ENABLE_LITERT only:
  litert source compiles for adapter-boundary tests.
  litert is not registered in EngineRegistry::production().
  litert is not returned by local_agent_engine_list.
  load_model is not reachable through the public registry.

With LOCAL_AGENT_ENABLE_LITERT and LOCAL_AGENT_ENABLE_LITERT_VENDOR:
  vendor LiteRT headers and library are linked.
  vendor bridge supplies make_litert_session().
  unavailable fallback litert_api.cpp is not compiled.
  litert registers descriptor metadata in the public production registry.
  load_model attempts real LiteRT model loading and maps vendor failures to stable local errors.
```

Registry descriptor when `LOCAL_AGENT_ENABLE_LITERT` and `LOCAL_AGENT_ENABLE_LITERT_VENDOR` are enabled:

```text
engine_id: litert
display_name: LiteRT
supported_model_formats: litert, tflite
supports_streaming: true
supports_cancellation: true
supports_vision: false
supports_token_usage: false
```

Extend `engine_registry_contract.cpp` for non-vendor hidden verification:

```cpp
bool expect_litert_hidden = argc > 1 && std::string(argv[1]) == "--expect-litert-hidden";
if (expect_litert_hidden) {
    auto production_registry = local_agent::EngineRegistry::production();
    auto descriptors = production_registry.list();
    assert(std::none_of(descriptors.begin(), descriptors.end(), [](const auto &descriptor) {
        return descriptor.engine_id == "litert";
    }));
    assert(production_registry.find("litert") == nullptr);
}
```

Add a LiteRT-specific runner section:

```bash
"$CXX_BIN" "${CXXFLAGS[@]}" -DLOCAL_AGENT_ENABLE_LITERT \
  inference/tests/engine_registry_contract.cpp \
  inference/core/token_stream.cpp \
  inference/core/engine_registry.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o "$BUILD_DIR/engine_registry_litert_contract"
"$BUILD_DIR/engine_registry_litert_contract" --expect-litert-hidden

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/litert_backend_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/generation_request.cpp \
  inference/core/token_stream.cpp \
  inference/backends/litert/litert_api.cpp \
  inference/backends/litert/litert_engine.cpp \
  -o "$BUILD_DIR/litert_backend_contract"
"$BUILD_DIR/litert_backend_contract"
```

Verification command:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
```

Expected output:

```text
local inference C++ contracts passed
```

Commit:

```bash
git add local-ios-agent/inference/backends/litert/litert_engine.h \
  local-ios-agent/inference/backends/litert/litert_api.h \
  local-ios-agent/inference/backends/litert/litert_api.cpp \
  local-ios-agent/inference/backends/litert/litert_engine.cpp \
  local-ios-agent/inference/core/engine_registry.cpp \
  local-ios-agent/inference/tests/engine_registry_contract.cpp \
  local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "feat: add litert local inference adapter boundary"
```

## Task 11: Record Swift/Rust Bridge Takeover Boundary

- [ ] Add a short note to this plan's completion handoff that Rust direct C++ local inference feature flags fail fast until Swift HostInferenceRuntime owns the v2 local route.
- [ ] Do not edit `local-ios-agent/rust-core/build.rs` in this C++-only implementation plan.
- [ ] Do not remove Rust local inference feature wiring in this C++-only implementation plan.
- [ ] Name the follow-up plan: Swift/Rust HostInference takeover.

Boundary note to preserve in the final handoff:

```text
This C++ refactor defines the v2 local inference boundary, removes the public v1 C ABI from the C++ library, and disables Rust's old direct local inference feature flags with a clear retirement message. The app-facing replacement route belongs to the later Swift/Rust HostInference takeover, in the same change that gives Swift a LocalCppInferenceClient.
```

Verification command:

```bash
rg -n "r[e]move rust local inference build glue|R[e]move Rust Local C[+][+] Build Glue|r[e]factor: r[e]move rust local inference build glue" local-ios-agent/docs/superpowers/plans/2026-07-04-local-cpp-inference-engine-implementation.md
```

Expected output:

```text
rg has no matches
```

## Task 12: Final Verification And Architecture Review

- [ ] Run all C++ local inference contracts.
- [ ] Check that public C ABI contains no Swift, Rust, cloud, provider, API key, or tool-call concepts.
- [ ] Check release registry behavior excludes `mock`.
- [ ] Check v1 `local_agent_backend_*` symbols are absent from the public header and C API implementation.
- [ ] Check string ownership is explicit in header comments.

Commands:

```bash
local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
rg -n "CloudInference|api_key|provider|tool_call|ToolCall|Conversation|AgentProfile|Rust|local_agent_backend_|LocalAgentBackend" local-ios-agent/inference
git diff --check
git status --short
```

Expected results:

```text
local inference C++ contracts passed
rg returns no architecture-boundary violations or legacy v1 ABI symbols under local-ios-agent/inference
git diff --check has no output
git status shows only intended local inference/build/test files before final commit
```

Final commit if any verification-only fixes were needed:

```bash
git add local-ios-agent/inference local-ios-agent/scripts/run-local-inference-cpp-contracts.sh
git commit -m "test: verify local cpp inference engine boundary"
```

## Completion Criteria

- v2 ABI exposes engine, model, and generation handles.
- `local_agent_string_free` owns all returned JSON/string deallocation.
- Engine list/capability JSON is available from C.
- Release registry does not expose `mock`.
- Test/debug registry exposes deterministic `mock`.
- Model load config and generation request are separate.
- Request-scoped prompt/image state lives in `GenerationSession`, not `InferenceEngine`.
- v2 image buffers are copied before `local_agent_generation_start` returns.
- Token events include text, reasoning, structured, usage, completed, and error forms; no tool-call event names exist in C++.
- LiteRT has a vendor-gated adapter boundary and registry descriptor path.
- v1 `local_agent_backend_*` ABI is removed from the public header and C API implementation.
- Rust direct C++ local inference feature flags fail fast with a retirement message; Swift/Rust HostInference takeover remains the follow-up for the app-facing local route.
- Filesystem naming cleanup from `inference/backends` to a future `local-inference/adapters` shape is intentionally deferred to a separate path-migration change.
- C++ local inference remains behind Swift's local route and is not an app-level inference router.
