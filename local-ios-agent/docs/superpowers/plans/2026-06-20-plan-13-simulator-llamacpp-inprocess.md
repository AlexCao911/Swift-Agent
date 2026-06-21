# Plan 13 Simulator llama.cpp In-Process Inference Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an in-process iOS Simulator real-model inference path that loads a GGUF model inside the app process and runs generation through a physically isolated, replaceable llama.cpp backend.

**Architecture:** SwiftUI owns provider selection and presentation only. Swift application code depends on `AgentRuntimeServicing` and `LLMEngineProtocol`, never on C++, llama.cpp headers, or model memory ownership. Rust owns runtime state, provider selection, context construction, tool orchestration, cancellation, and maps `ModelProviderOutput` into runtime events. C++ owns model configuration parsing, backend lifecycle, token production, stream-local cancellation, and release; llama.cpp is one replaceable backend behind an internal `InferenceEngine` interface, not the architecture center.

**Tech Stack:** SwiftUI MVVM, LocalAgentBridge, Objective-C++ anti-corruption bridge, Rust 2021, C ABI, C++17, llama.cpp XCFramework / static library, GGUF model artifacts outside git, cargo tests, clang++ tests, xcodebuild tests.

---

## Decision

Plan 13's mainline is:

```text
Xcode iOS Simulator App
  -> AgentRuntimeService
  -> RustRuntimeClient
  -> C ABI
  -> Rust AgentRuntime
  -> LocalLLMProvider
  -> LocalInferenceBackend
  -> local_agent_inference.h C ABI
  -> C++ backend facade
  -> llama.cpp backend
  -> local GGUF model file
```

Swift-native smoke adapters use a side path:

```text
LLMEngineProtocol
  -> NativeLlamaEngineAdapter
  -> LlamaBridge.h/.mm
  -> local_agent_inference.h C ABI
  -> C++ backend facade
```

This verifies app-process model loading, prompt conversion, token streaming, cancellation, release, and UI recovery. It still does not prove iPhone thermal, battery, Neural Engine, or final Metal performance. Those remain true-device acceptance criteria.

## Non-Goals

- Do not route Plan 13 inference through an external model service.
- Do not make C++ know about sessions, runs, tools, memory, approval policy, SwiftUI, or Rust runtime internals.
- Do not hardcode MiniCPM into C++ or Rust provider names.
- Do not make llama.cpp the only possible inference engine.
- Do not drag llama.cpp source files or C++ headers into SwiftUI, ViewModel, or app domain files.
- Do not commit model weights into git.
- Do not add model download automation to the app.
- Do not implement native iOS tools in this plan.

## Inputs

- llama.cpp official build docs state the main product is the `llama` library and its C-style interface lives in `include/llama.h`: `https://raw.githubusercontent.com/ggml-org/llama.cpp/master/docs/build.md`
- llama.cpp official SwiftUI example states `build-xcframework.sh` creates an XCFramework that can run on simulator or real device: `https://raw.githubusercontent.com/ggml-org/llama.cpp/master/examples/llama.swiftui/README.md`
- llama.cpp `mtmd.h` documents experimental multimodal support through RGB bitmaps and `mtmd_tokenize`: `https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/mtmd/mtmd.h`
- Kiro requirements: `local-ios-agent/.kiro/specs/on-device-inference-architecture/requirements.md`
- Kiro design: `local-ios-agent/.kiro/specs/on-device-inference-architecture/design.md`
- Kiro tasks: `local-ios-agent/.kiro/specs/on-device-inference-architecture/tasks.md`

Kiro ideas retained here:

- Pure C ABI between Rust and native inference.
- Safe Rust wrapper with `Drop`, input validation, cancellation propagation, and backend trait abstraction.
- Mock backend tests for no-model CI.
- Property-style contracts for parsing, resource cleanup, error propagation, concurrency, and cancellation.
- Token streaming must be real callback streaming; Rust must not collect a full `Vec` before the Swift UI can observe deltas.

Kiro ideas corrected here:

- Provider and engine names are model-neutral: `local_llm`, `LocalLLMProvider`, `LocalInferenceBackend`, `LLMEngineProtocol`.
- llama.cpp is linked as an external binary artifact, not vendored into the app target as source.
- Swift may use an Objective-C++ anti-corruption bridge only through a protocol adapter; SwiftUI and ViewModels never import the bridge.

## File Structure

Create:

```text
local-ios-agent/docs/model-providers/simulator-llamacpp-contract.md
local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md
local-ios-agent/docs/model-providers/swift-llm-clean-architecture.md
local-ios-agent/docs/model-evaluation/simulator-llamacpp-report.md
local-ios-agent/inference/core/model_config.h
local-ios-agent/inference/core/model_config.cpp
local-ios-agent/inference/core/inference_engine.h
local-ios-agent/inference/core/token_event.h
local-ios-agent/inference/core/token_stream.h
local-ios-agent/inference/core/token_stream.cpp
local-ios-agent/inference/c_api/local_agent_inference.cpp
local-ios-agent/inference/backends/mock/mock_inference_engine.h
local-ios-agent/inference/backends/mock/mock_inference_engine.cpp
local-ios-agent/inference/backends/llama_cpp/llama_cpp_engine.h
local-ios-agent/inference/backends/llama_cpp/llama_cpp_engine.cpp
local-ios-agent/inference/backends/llama_cpp/llama_cpp_api.h
local-ios-agent/inference/backends/llama_cpp/llama_cpp_api.cpp
local-ios-agent/inference/objc_bridge/LlamaBridge.h
local-ios-agent/inference/objc_bridge/LlamaBridge.mm
local-ios-agent/inference/tests/model_config_contract.cpp
local-ios-agent/inference/tests/token_stream_contract.cpp
local-ios-agent/inference/tests/c_api_backend_contract.cpp
local-ios-agent/inference/tests/llama_cpp_backend_contract.cpp
local-ios-agent/inference/tests/objc_bridge_header_contract.m
local-ios-agent/rust-core/tests/local_llm_provider.rs
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain/LLMEngineProtocol.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain/StructuredOutput.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Infrastructure/NativeInference/NativeLlamaEngineAdapter.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Domain/LLMEngineProtocolTests.swift
local-ios-agent/scripts/build-llama-cpp-xcframework.sh
local-ios-agent/scripts/build-local-inference-simulator.sh
local-ios-agent/scripts/run-simulator-llamacpp-smoke.sh
```

Modify:

```text
local-ios-agent/inference/include/local_agent_inference.h
local-ios-agent/inference/mock/local_agent_inference_mock.cpp
local-ios-agent/rust-core/build.rs
local-ios-agent/rust-core/Cargo.toml
local-ios-agent/rust-core/src/core/mod.rs
local-ios-agent/rust-core/src/core/local_llm.rs
local-ios-agent/rust-core/src/ffi_bridge.rs
local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift
local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift
local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift
local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift
local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift
```

Plan 13 is an in-process inference plan. Historical provider experiments are outside this plan.

## Boundary Contract

The C ABI remains narrow:

```c
LocalAgentStatus local_agent_backend_init(LocalAgentBackend **out_backend);
LocalAgentStatus local_agent_backend_load_model(LocalAgentBackend *backend, const char *model_config_json);
LocalAgentStatus local_agent_backend_start_chat(LocalAgentBackend *backend, const char *prompt_json, LocalAgentBackendStream **out_stream);
LocalAgentStatus local_agent_backend_start_chat_with_image(LocalAgentBackend *backend, const char *prompt_json, const unsigned char *rgb_data, uint32_t width, uint32_t height, LocalAgentBackendStream **out_stream);
LocalAgentStatus local_agent_backend_read_stream(LocalAgentBackendStream *stream, local_agent_token_callback callback, void *user_data);
LocalAgentStatus local_agent_backend_cancel(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release_stream(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release(LocalAgentBackend *backend);
```

The model config selects the backend and model artifact:

```json
{
  "backend": "llama_cpp",
  "model_id": "local.gguf.simulator",
  "model_path": "/absolute/path/to/model.gguf",
  "chat_template": "gguf",
  "max_context_tokens": 2048,
  "generation": {
    "temperature": 0.2,
    "top_p": 0.9,
    "max_new_tokens": 128,
    "seed": 42
  },
  "llama_cpp": {
    "n_gpu_layers": 0,
    "n_threads": 4,
    "mmproj_path": ""
  }
}
```

MiniCPM is a candidate `model_id`, not a provider or backend name. It can be used only if the selected artifact is loadable by llama.cpp on iOS Simulator.

## Clean Architecture Boundary

The dependency direction is fixed:

```text
SwiftUI View
  -> AgentViewModel
  -> AgentRuntimeServicing / LLMEngineProtocol
  -> RustRuntimeClient or NativeLlamaEngineAdapter
  -> Rust FFI or Objective-C++ bridge
  -> C ABI
  -> C++ InferenceEngine
  -> llama.cpp XCFramework
```

Rules:

- SwiftUI and ViewModels import only Swift domain protocols and DTOs.
- `LlamaBridge.h` exposes only Objective-C and Foundation/UIKit types: `NSString`, `NSError`, `UIImage`, blocks, and `BOOL`.
- `LlamaBridge.h` must not include `<vector>`, `<string>`, `<memory>`, `llama.h`, `mtmd.h`, or any project C++ header.
- `LlamaBridge.mm` may include C++ and C ABI headers privately.
- The app target links a produced `llama.xcframework` or static library. The app target does not compile llama.cpp upstream source files directly.
- Token deltas move upward by callback/closure and `AsyncThrowingStream`; no layer waits for the entire generation before emitting UI-visible deltas.
- Replacing llama.cpp with MLX, Core ML, MLC, ExecuTorch, or another backend requires a new adapter and/or `InferenceEngine`, not ViewModel, reducer, tool driver, or Rust runtime state-machine changes.

## Task 1: Write In-Process Inference Contracts And Remove Stale Plan

**Files:**
- Create: `local-ios-agent/docs/model-providers/simulator-llamacpp-contract.md`
- Create: `local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md`
- Create: `local-ios-agent/docs/model-providers/swift-llm-clean-architecture.md`
- Create: `local-ios-agent/docs/model-evaluation/simulator-llamacpp-report.md`

- [ ] **Step 1: Write the simulator contract document**

Create `local-ios-agent/docs/model-providers/simulator-llamacpp-contract.md`:

```markdown
# Simulator llama.cpp Model Contract

Plan 13 loads a GGUF model inside the iOS Simulator app process through the local inference C ABI.

## Required Local Environment

```bash
export LOCAL_AGENT_SIMULATOR_MODEL_CONFIG=/absolute/path/to/local-agent-simulator-model.json
export LOCAL_AGENT_SIMULATOR_GGUF=/absolute/path/to/model.gguf
```

`LOCAL_AGENT_SIMULATOR_MODEL_CONFIG` must contain:

```json
{
  "backend": "llama_cpp",
  "model_id": "local.gguf.simulator",
  "model_path": "/absolute/path/to/model.gguf",
  "chat_template": "gguf",
  "max_context_tokens": 2048,
  "generation": {
    "temperature": 0.2,
    "top_p": 0.9,
    "max_new_tokens": 128,
    "seed": 42
  },
  "llama_cpp": {
    "n_gpu_layers": 0,
    "n_threads": 4,
    "mmproj_path": ""
  }
}
```

## Model Acceptance Gate

The selected model must pass all gates:

1. The file is GGUF.
2. llama.cpp can load it on macOS with `llama-cli`.
3. The iOS Simulator build can load it through `local_agent_backend_load_model`.
4. A single prompt produces at least one `text_delta` and one `completed` token event.
5. Cancellation releases the stream exactly once.

MiniCPM may be used only when its artifact satisfies these gates. If a MiniCPM artifact cannot be loaded by llama.cpp, record that result and use a smaller compatible GGUF for the architecture smoke while keeping the backend model-agnostic.
```

- [ ] **Step 2: Write the C++ architecture document**

Create `local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md`:

```markdown
# C++ Inference Backend Architecture

The C++ layer is model-agnostic and backend-agnostic.

## Layers

```text
local_agent_inference.h
  Stable C ABI.

c_api/local_agent_inference.cpp
  Converts opaque C handles to C++ objects and maps exceptions/errors to LocalAgentStatus.

core/model_config.*
  Parses model_config_json and validates backend/model/generation fields.

core/inference_engine.h
  Defines the replaceable backend interface.

core/token_stream.*
  Owns one generation stream, cancellation state, and token callback delivery.

backends/mock/*
  Deterministic engine for tests.

backends/llama_cpp/*
  llama.cpp engine and llama API shim.
```

## Forbidden Dependencies

C++ code must not include Rust headers, Swift headers, session IDs, run IDs, tool call IDs, or provider registry types.

## Replacement Rule

Replacing llama.cpp with Core ML, MLC, ExecuTorch, or another engine must only require a new `InferenceEngine` implementation and a new backend factory branch. C ABI, Rust runtime, and SwiftUI must remain unchanged.
```

- [ ] **Step 3: Write Swift clean architecture document**

Create `local-ios-agent/docs/model-providers/swift-llm-clean-architecture.md`:

```markdown
# Swift LLM Clean Architecture

Swift code must treat local inference as a business capability, not as a C++ library.

## Public Swift Boundary

```swift
protocol StructuredOutput: Decodable, Sendable {}

enum LLMTokenEvent: Equatable, Sendable {
    case textDelta(String)
    case completed(String)
}

protocol LLMEngineProtocol: Sendable {
    func stream(prompt: String, image: UIImage?) -> AsyncThrowingStream<LLMTokenEvent, Error>
    func predict<T: StructuredOutput>(prompt: String, image: UIImage?, as type: T.Type) async throws -> T
}
```

## Adapter Rule

`NativeLlamaEngineAdapter` may depend on `LlamaBridge`. `AgentViewModel`, `ChatView`, reducers, tool drivers, and runtime state must not import `LlamaBridge`.

## Objective-C++ Header Rule

`LlamaBridge.h` is a Swift import surface. It may expose `NSString`, `NSError`, `UIImage`, blocks, and Objective-C classes only. It must not expose C++ standard library types, llama.cpp headers, project C++ headers, raw model pointers, or manual memory ownership rules.

## Physical Link Rule

The app links a prebuilt `llama.xcframework` or static library. Upstream llama.cpp source files stay outside the Xcode app target. Backend updates happen by rebuilding the library artifact and rerunning native bridge tests.

## Streaming Rule

Native token callbacks must be bridged into `AsyncThrowingStream` immediately. Collecting a full completion before updating Swift state violates this contract.
```

- [ ] **Step 4: Commit**

Run:

```bash
git add local-ios-agent/docs/model-providers/simulator-llamacpp-contract.md \
  local-ios-agent/docs/model-providers/cpp-inference-backend-architecture.md \
  local-ios-agent/docs/model-providers/swift-llm-clean-architecture.md \
  local-ios-agent/docs/model-evaluation/simulator-llamacpp-report.md \
  local-ios-agent/docs/superpowers/plans/2026-06-20-plan-13-simulator-llamacpp-inprocess.md
git commit -m "docs: define simulator llama cpp inference architecture"
```

## Task 2: Add C++ Model Config Parser

**Files:**
- Create: `local-ios-agent/inference/core/model_config.h`
- Create: `local-ios-agent/inference/core/model_config.cpp`
- Test: `local-ios-agent/inference/tests/model_config_contract.cpp`

- [ ] **Step 1: Write failing parser contract test**

Create `local-ios-agent/inference/tests/model_config_contract.cpp`:

```cpp
#include "model_config.h"

#include <cassert>
#include <string>

int main() {
    const std::string json = R"({
      "backend": "llama_cpp",
      "model_id": "local.gguf.simulator",
      "model_path": "/tmp/model.gguf",
      "chat_template": "gguf",
      "max_context_tokens": 2048,
      "generation": {
        "temperature": 0.2,
        "top_p": 0.9,
        "max_new_tokens": 128,
        "seed": 42
      },
      "llama_cpp": {
        "n_gpu_layers": 0,
        "n_threads": 4,
        "mmproj_path": ""
      }
    })";

    local_agent::ModelConfig config = local_agent::parse_model_config(json.c_str());
    assert(config.backend == "llama_cpp");
    assert(config.model_id == "local.gguf.simulator");
    assert(config.model_path == "/tmp/model.gguf");
    assert(config.chat_template == "gguf");
    assert(config.max_context_tokens == 2048);
    assert(config.generation.temperature == 0.2f);
    assert(config.generation.top_p == 0.9f);
    assert(config.generation.max_new_tokens == 128);
    assert(config.generation.seed == 42);
    assert(config.llama_cpp.n_gpu_layers == 0);
    assert(config.llama_cpp.n_threads == 4);
    assert(config.llama_cpp.mmproj_path.empty());

    bool rejected_empty_model_path = false;
    try {
        local_agent::parse_model_config(R"({"backend":"llama_cpp","model_path":""})");
    } catch (const std::exception&) {
        rejected_empty_model_path = true;
    }
    assert(rejected_empty_model_path);

    bool rejected_unknown_backend = false;
    try {
        local_agent::parse_model_config(R"({"backend":"one_big_hardcoded_model","model_path":"/tmp/model.gguf"})");
    } catch (const std::exception&) {
        rejected_unknown_backend = true;
    }
    assert(rejected_unknown_backend);

    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 -I inference/include -I inference/core \
  inference/tests/model_config_contract.cpp \
  inference/core/model_config.cpp \
  -o /tmp/model_config_contract
```

Expected: FAIL because `model_config.h` and `model_config.cpp` do not exist.

- [ ] **Step 3: Implement parser header**

Create `local-ios-agent/inference/core/model_config.h`:

```cpp
#ifndef LOCAL_AGENT_MODEL_CONFIG_H
#define LOCAL_AGENT_MODEL_CONFIG_H

#include <cstdint>
#include <string>

namespace local_agent {

struct GenerationConfig {
    float temperature = 0.2f;
    float top_p = 0.9f;
    int max_new_tokens = 128;
    int seed = 42;
};

struct LlamaCppConfig {
    int n_gpu_layers = 0;
    int n_threads = 4;
    std::string mmproj_path;
};

struct ModelConfig {
    std::string backend;
    std::string model_id;
    std::string model_path;
    std::string chat_template;
    int max_context_tokens = 2048;
    GenerationConfig generation;
    LlamaCppConfig llama_cpp;
};

ModelConfig parse_model_config(const char *model_config_json);
std::string require_json_string(const std::string &json, const std::string &key);
int optional_json_int(const std::string &json, const std::string &key, int fallback);
float optional_json_float(const std::string &json, const std::string &key, float fallback);
std::string optional_json_string(const std::string &json, const std::string &key, const std::string &fallback);

} // namespace local_agent

#endif
```

- [ ] **Step 4: Implement minimal parser**

Create `local-ios-agent/inference/core/model_config.cpp`:

```cpp
#include "model_config.h"

#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

namespace local_agent {
namespace {

std::string find_raw_value(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const std::size_t key_pos = json.find(needle);
    if (key_pos == std::string::npos) {
        return "";
    }
    const std::size_t colon_pos = json.find(':', key_pos + needle.size());
    if (colon_pos == std::string::npos) {
        return "";
    }
    std::size_t value_start = json.find_first_not_of(" \n\r\t", colon_pos + 1);
    if (value_start == std::string::npos) {
        return "";
    }
    if (json[value_start] == '"') {
        const std::size_t value_end = json.find('"', value_start + 1);
        if (value_end == std::string::npos) {
            throw std::invalid_argument("unterminated string for key: " + key);
        }
        return json.substr(value_start + 1, value_end - value_start - 1);
    }
    const std::size_t value_end = json.find_first_of(",}\n\r\t ", value_start);
    return json.substr(value_start, value_end - value_start);
}

void require_non_empty(const std::string &value, const std::string &key) {
    if (value.empty()) {
        throw std::invalid_argument("missing required model config key: " + key);
    }
}

} // namespace

std::string require_json_string(const std::string &json, const std::string &key) {
    std::string value = find_raw_value(json, key);
    require_non_empty(value, key);
    return value;
}

int optional_json_int(const std::string &json, const std::string &key, int fallback) {
    std::string value = find_raw_value(json, key);
    if (value.empty()) {
        return fallback;
    }
    return std::atoi(value.c_str());
}

float optional_json_float(const std::string &json, const std::string &key, float fallback) {
    std::string value = find_raw_value(json, key);
    if (value.empty()) {
        return fallback;
    }
    return static_cast<float>(std::atof(value.c_str()));
}

std::string optional_json_string(const std::string &json, const std::string &key, const std::string &fallback) {
    std::string value = find_raw_value(json, key);
    if (value.empty()) {
        return fallback;
    }
    return value;
}

ModelConfig parse_model_config(const char *model_config_json) {
    if (model_config_json == nullptr) {
        throw std::invalid_argument("model config json is null");
    }
    const std::string json(model_config_json);
    ModelConfig config;
    config.backend = require_json_string(json, "backend");
    config.model_path = require_json_string(json, "model_path");
    config.model_id = find_raw_value(json, "model_id");
    if (config.model_id.empty()) {
        config.model_id = config.model_path;
    }
    config.chat_template = find_raw_value(json, "chat_template");
    if (config.chat_template.empty()) {
        config.chat_template = "gguf";
    }
    config.max_context_tokens = optional_json_int(json, "max_context_tokens", 2048);
    config.generation.temperature = optional_json_float(json, "temperature", 0.2f);
    config.generation.top_p = optional_json_float(json, "top_p", 0.9f);
    config.generation.max_new_tokens = optional_json_int(json, "max_new_tokens", 128);
    config.generation.seed = optional_json_int(json, "seed", 42);
    config.llama_cpp.n_gpu_layers = optional_json_int(json, "n_gpu_layers", 0);
    config.llama_cpp.n_threads = optional_json_int(json, "n_threads", 4);
    config.llama_cpp.mmproj_path = optional_json_string(json, "mmproj_path", "");

    if (config.backend != "mock" && config.backend != "llama_cpp") {
        throw std::invalid_argument("unsupported inference backend: " + config.backend);
    }
    if (config.max_context_tokens <= 0) {
        throw std::invalid_argument("max_context_tokens must be positive");
    }
    if (config.generation.max_new_tokens <= 0) {
        throw std::invalid_argument("max_new_tokens must be positive");
    }
    return config;
}

} // namespace local_agent
```

This parser is deliberately small and test-owned. If nested parsing becomes fragile during implementation, replace only `model_config.cpp` with a structured parser while preserving `ModelConfig`.

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 -I inference/include -I inference/core \
  inference/tests/model_config_contract.cpp \
  inference/core/model_config.cpp \
  -o /tmp/model_config_contract
/tmp/model_config_contract
```

Expected: PASS with exit code 0.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/inference/core/model_config.h \
  local-ios-agent/inference/core/model_config.cpp \
  local-ios-agent/inference/tests/model_config_contract.cpp
git commit -m "Add simulator model config parser"
```

## Task 3: Add C++ Engine Interface And Token Stream

**Files:**
- Create: `local-ios-agent/inference/core/inference_engine.h`
- Create: `local-ios-agent/inference/core/token_event.h`
- Create: `local-ios-agent/inference/core/token_stream.h`
- Create: `local-ios-agent/inference/core/token_stream.cpp`
- Test: `local-ios-agent/inference/tests/token_stream_contract.cpp`

- [ ] **Step 1: Write failing token stream test**

Create `local-ios-agent/inference/tests/token_stream_contract.cpp`:

```cpp
#include "token_stream.h"

#include <cassert>
#include <string>
#include <vector>

int main() {
    local_agent::TokenStream stream;
    std::vector<std::string> tokens;
    stream.emit_text_delta("hello", [&](const std::string &json) {
        tokens.push_back(json);
    });
    stream.emit_completed("hello", [&](const std::string &json) {
        tokens.push_back(json);
    });
    assert(tokens.size() == 2);
    assert(tokens[0] == R"({"type":"text_delta","text":"hello"})");
    assert(tokens[1] == R"({"type":"completed","text":"hello"})");

    stream.cancel();
    assert(stream.is_cancelled());
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 -I inference/core \
  inference/tests/token_stream_contract.cpp \
  inference/core/token_stream.cpp \
  -o /tmp/token_stream_contract
```

Expected: FAIL because token stream files do not exist.

- [ ] **Step 3: Implement engine and token stream headers**

Create `local-ios-agent/inference/core/token_event.h`:

```cpp
#ifndef LOCAL_AGENT_TOKEN_EVENT_H
#define LOCAL_AGENT_TOKEN_EVENT_H

#include <string>

namespace local_agent {

inline std::string escape_json_text(const std::string &text) {
    std::string escaped;
    for (char c : text) {
        if (c == '\\') {
            escaped += "\\\\";
        } else if (c == '"') {
            escaped += "\\\"";
        } else if (c == '\n') {
            escaped += "\\n";
        } else {
            escaped += c;
        }
    }
    return escaped;
}

inline std::string token_event_json(const std::string &type, const std::string &text) {
    return "{\"type\":\"" + type + "\",\"text\":\"" + escape_json_text(text) + "\"}";
}

} // namespace local_agent

#endif
```

Create `local-ios-agent/inference/core/token_stream.h`:

```cpp
#ifndef LOCAL_AGENT_TOKEN_STREAM_H
#define LOCAL_AGENT_TOKEN_STREAM_H

#include <atomic>
#include <functional>
#include <string>

namespace local_agent {

class TokenStream {
public:
    using Emit = std::function<void(const std::string &)>;

    void cancel();
    bool is_cancelled() const;
    void emit_text_delta(const std::string &text, const Emit &emit);
    void emit_completed(const std::string &text, const Emit &emit);

private:
    std::atomic<bool> cancelled_{false};
};

} // namespace local_agent

#endif
```

Create `local-ios-agent/inference/core/inference_engine.h`:

```cpp
#ifndef LOCAL_AGENT_INFERENCE_ENGINE_H
#define LOCAL_AGENT_INFERENCE_ENGINE_H

#include "model_config.h"
#include "token_stream.h"

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace local_agent {

struct ImageInput {
    std::vector<unsigned char> rgb_data;
    uint32_t width = 0;
    uint32_t height = 0;
};

class InferenceEngine {
public:
    virtual ~InferenceEngine() = default;
    virtual void load(const ModelConfig &config) = 0;
    virtual std::unique_ptr<TokenStream> start_chat(const std::string &prompt_json) = 0;
    virtual std::unique_ptr<TokenStream> start_chat_with_image(
        const std::string &prompt_json,
        const ImageInput &
    ) {
        throw std::invalid_argument("image input is not supported by this backend");
    }
    virtual void read_stream(TokenStream &stream, const TokenStream::Emit &emit) = 0;
};

std::unique_ptr<InferenceEngine> make_inference_engine(const ModelConfig &config);

} // namespace local_agent

#endif
```

- [ ] **Step 4: Implement token stream**

Create `local-ios-agent/inference/core/token_stream.cpp`:

```cpp
#include "token_stream.h"
#include "token_event.h"

namespace local_agent {

void TokenStream::cancel() {
    cancelled_.store(true);
}

bool TokenStream::is_cancelled() const {
    return cancelled_.load();
}

void TokenStream::emit_text_delta(const std::string &text, const Emit &emit) {
    if (!is_cancelled()) {
        emit(token_event_json("text_delta", text));
    }
}

void TokenStream::emit_completed(const std::string &text, const Emit &emit) {
    if (!is_cancelled()) {
        emit(token_event_json("completed", text));
    }
}

} // namespace local_agent
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 -I inference/core \
  inference/tests/token_stream_contract.cpp \
  inference/core/token_stream.cpp \
  -o /tmp/token_stream_contract
/tmp/token_stream_contract
```

Expected: PASS with exit code 0.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/inference/core/inference_engine.h \
  local-ios-agent/inference/core/token_event.h \
  local-ios-agent/inference/core/token_stream.h \
  local-ios-agent/inference/core/token_stream.cpp \
  local-ios-agent/inference/tests/token_stream_contract.cpp
git commit -m "Add local inference engine boundary"
```

## Task 4: Refactor C ABI Onto Engine Boundary With Mock Backend

**Files:**
- Modify: `local-ios-agent/inference/include/local_agent_inference.h`
- Create: `local-ios-agent/inference/c_api/local_agent_inference.cpp`
- Create: `local-ios-agent/inference/backends/mock/mock_inference_engine.h`
- Create: `local-ios-agent/inference/backends/mock/mock_inference_engine.cpp`
- Modify: `local-ios-agent/inference/mock/local_agent_inference_mock.cpp`
- Test: `local-ios-agent/inference/tests/c_api_backend_contract.cpp`
- Modify: `local-ios-agent/rust-core/build.rs`

- [ ] **Step 1: Write failing C ABI contract test**

Create `local-ios-agent/inference/tests/c_api_backend_contract.cpp`:

```cpp
#include "local_agent_inference.h"

#include <cassert>
#include <string>
#include <vector>

struct CallbackState {
    std::vector<std::string> tokens;
};

static void collect_token(const char *token_json, void *user_data) {
    auto *state = static_cast<CallbackState *>(user_data);
    state->tokens.emplace_back(token_json);
}

int main() {
    LocalAgentBackend *backend = nullptr;
    assert(local_agent_backend_init(&backend) == LOCAL_AGENT_STATUS_OK);
    assert(backend != nullptr);

    const char *config = R"({
      "backend":"mock",
      "model_id":"mock.local",
      "model_path":"/tmp/mock.gguf",
      "max_context_tokens":128,
      "generation":{"max_new_tokens":8}
    })";
    assert(local_agent_backend_load_model(backend, config) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *stream = nullptr;
    assert(local_agent_backend_start_chat(backend, R"({"messages":[{"role":"user","content":"hello"}]})", &stream) == LOCAL_AGENT_STATUS_OK);
    assert(stream != nullptr);

    CallbackState state;
    assert(local_agent_backend_read_stream(stream, collect_token, &state) == LOCAL_AGENT_STATUS_OK);
    assert(state.tokens.size() == 3);
    assert(state.tokens[0] == R"({"type":"text_delta","text":"On-device "})");
    assert(state.tokens[2] == R"({"type":"completed","text":"On-device mock response"})");
    assert(local_agent_backend_release_stream(stream) == LOCAL_AGENT_STATUS_OK);

    LocalAgentBackendStream *image_stream = nullptr;
    assert(local_agent_backend_start_chat_with_image(backend, R"({"messages":[]})", nullptr, 1, 1, &image_stream) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(image_stream == nullptr);
    const unsigned char rgb_pixel[3] = {255, 255, 255};
    assert(local_agent_backend_start_chat_with_image(backend, R"({"messages":[]})", rgb_pixel, 1, 1, &image_stream) == LOCAL_AGENT_STATUS_INVALID_ARGUMENT);
    assert(image_stream == nullptr);

    LocalAgentBackendStream *cancelled = nullptr;
    assert(local_agent_backend_start_chat(backend, R"({"messages":[]})", &cancelled) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_backend_cancel(cancelled) == LOCAL_AGENT_STATUS_CANCELLED);
    assert(local_agent_backend_release_stream(cancelled) == LOCAL_AGENT_STATUS_OK);
    assert(local_agent_backend_release(backend) == LOCAL_AGENT_STATUS_OK);
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails before refactor**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 \
  -I inference/include -I inference/core -I inference/backends/mock \
  inference/tests/c_api_backend_contract.cpp \
  inference/c_api/local_agent_inference.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o /tmp/c_api_backend_contract
```

Expected: FAIL because new C ABI implementation files do not exist.

- [ ] **Step 3: Update C ABI header**

Modify `local-ios-agent/inference/include/local_agent_inference.h`:

```c
#ifndef LOCAL_AGENT_INFERENCE_H
#define LOCAL_AGENT_INFERENCE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum LocalAgentStatus {
    LOCAL_AGENT_STATUS_OK = 0,
    LOCAL_AGENT_STATUS_ERROR = 1,
    LOCAL_AGENT_STATUS_CANCELLED = 2,
    LOCAL_AGENT_STATUS_INVALID_ARGUMENT = 3
} LocalAgentStatus;

typedef struct LocalAgentBackend LocalAgentBackend;
typedef struct LocalAgentBackendStream LocalAgentBackendStream;

typedef void (*local_agent_token_callback)(const char *token_json, void *user_data);

LocalAgentStatus local_agent_backend_init(LocalAgentBackend **out_backend);
LocalAgentStatus local_agent_backend_load_model(LocalAgentBackend *backend, const char *model_config_json);
LocalAgentStatus local_agent_backend_start_chat(LocalAgentBackend *backend, const char *prompt_json, LocalAgentBackendStream **out_stream);
LocalAgentStatus local_agent_backend_start_chat_with_image(LocalAgentBackend *backend, const char *prompt_json, const unsigned char *rgb_data, uint32_t width, uint32_t height, LocalAgentBackendStream **out_stream);
LocalAgentStatus local_agent_backend_read_stream(LocalAgentBackendStream *stream, local_agent_token_callback callback, void *user_data);
LocalAgentStatus local_agent_backend_cancel(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release_stream(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release(LocalAgentBackend *backend);

#ifdef __cplusplus
}
#endif

#endif
```

The header stays pure C: no C++ classes, templates, exceptions, STL, Swift types, or llama.cpp headers.

- [ ] **Step 4: Implement mock engine**

Create `local-ios-agent/inference/backends/mock/mock_inference_engine.h`:

```cpp
#ifndef LOCAL_AGENT_MOCK_INFERENCE_ENGINE_H
#define LOCAL_AGENT_MOCK_INFERENCE_ENGINE_H

#include "inference_engine.h"

namespace local_agent {

class MockInferenceEngine final : public InferenceEngine {
public:
    void load(const ModelConfig &config) override;
    std::unique_ptr<TokenStream> start_chat(const std::string &prompt_json) override;
    void read_stream(TokenStream &stream, const TokenStream::Emit &emit) override;

private:
    bool loaded_ = false;
};

} // namespace local_agent

#endif
```

Create `local-ios-agent/inference/backends/mock/mock_inference_engine.cpp`:

```cpp
#include "mock_inference_engine.h"

#include <stdexcept>

namespace local_agent {

void MockInferenceEngine::load(const ModelConfig &config) {
    if (config.model_path.empty()) {
        throw std::invalid_argument("mock model_path must not be empty");
    }
    loaded_ = true;
}

std::unique_ptr<TokenStream> MockInferenceEngine::start_chat(const std::string &prompt_json) {
    if (!loaded_) {
        throw std::runtime_error("mock inference engine is not loaded");
    }
    if (prompt_json.empty()) {
        throw std::invalid_argument("prompt json must not be empty");
    }
    return std::make_unique<TokenStream>();
}

void MockInferenceEngine::read_stream(TokenStream &stream, const TokenStream::Emit &emit) {
    stream.emit_text_delta("On-device ", emit);
    stream.emit_text_delta("mock response", emit);
    stream.emit_completed("On-device mock response", emit);
}

} // namespace local_agent
```

- [ ] **Step 5: Implement C ABI adapter**

Create `local-ios-agent/inference/c_api/local_agent_inference.cpp`:

```cpp
#include "local_agent_inference.h"

#include "inference_engine.h"
#include "mock_inference_engine.h"
#include "model_config.h"

#include <exception>
#include <memory>
#include <string>
#include <vector>

struct LocalAgentBackend {
    local_agent::ModelConfig config;
    std::unique_ptr<local_agent::InferenceEngine> engine;
};

struct LocalAgentBackendStream {
    local_agent::InferenceEngine *engine = nullptr;
    std::unique_ptr<local_agent::TokenStream> stream;
};

namespace local_agent {

std::unique_ptr<InferenceEngine> make_inference_engine(const ModelConfig &config) {
    if (config.backend == "mock") {
        return std::make_unique<MockInferenceEngine>();
    }
    throw std::invalid_argument("unsupported backend in this build: " + config.backend);
}

} // namespace local_agent

namespace {

LocalAgentStatus map_exception() {
    try {
        throw;
    } catch (const std::invalid_argument &) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    } catch (const std::exception &) {
        return LOCAL_AGENT_STATUS_ERROR;
    } catch (...) {
        return LOCAL_AGENT_STATUS_ERROR;
    }
}

} // namespace

extern "C" {

LocalAgentStatus local_agent_backend_init(LocalAgentBackend **out_backend) {
    if (out_backend == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    *out_backend = new LocalAgentBackend();
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_load_model(LocalAgentBackend *backend, const char *model_config_json) {
    if (backend == nullptr || model_config_json == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    try {
        backend->config = local_agent::parse_model_config(model_config_json);
        backend->engine = local_agent::make_inference_engine(backend->config);
        backend->engine->load(backend->config);
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_start_chat(LocalAgentBackend *backend, const char *prompt_json, LocalAgentBackendStream **out_stream) {
    if (backend == nullptr || prompt_json == nullptr || out_stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    if (!backend->engine) {
        return LOCAL_AGENT_STATUS_ERROR;
    }
    try {
        auto stream = new LocalAgentBackendStream();
        stream->engine = backend->engine.get();
        stream->stream = backend->engine->start_chat(prompt_json);
        *out_stream = stream;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        *out_stream = nullptr;
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_start_chat_with_image(
    LocalAgentBackend *backend,
    const char *prompt_json,
    const unsigned char *rgb_data,
    uint32_t width,
    uint32_t height,
    LocalAgentBackendStream **out_stream
) {
    if (backend == nullptr || prompt_json == nullptr || rgb_data == nullptr || width == 0 || height == 0 || out_stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    if (!backend->engine) {
        return LOCAL_AGENT_STATUS_ERROR;
    }
    try {
        local_agent::ImageInput image;
        image.width = width;
        image.height = height;
        image.rgb_data.assign(rgb_data, rgb_data + (static_cast<size_t>(width) * static_cast<size_t>(height) * 3));

        auto stream = new LocalAgentBackendStream();
        stream->engine = backend->engine.get();
        stream->stream = backend->engine->start_chat_with_image(prompt_json, image);
        *out_stream = stream;
        return LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        *out_stream = nullptr;
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_read_stream(LocalAgentBackendStream *stream, local_agent_token_callback callback, void *user_data) {
    if (stream == nullptr || stream->engine == nullptr || stream->stream == nullptr || callback == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    if (stream->stream->is_cancelled()) {
        return LOCAL_AGENT_STATUS_CANCELLED;
    }
    try {
        auto emit = [&](const std::string &json) {
            callback(json.c_str(), user_data);
        };
        stream->engine->read_stream(*stream->stream, emit);
        return stream->stream->is_cancelled() ? LOCAL_AGENT_STATUS_CANCELLED : LOCAL_AGENT_STATUS_OK;
    } catch (...) {
        return map_exception();
    }
}

LocalAgentStatus local_agent_backend_cancel(LocalAgentBackendStream *stream) {
    if (stream == nullptr || stream->stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    stream->stream->cancel();
    return LOCAL_AGENT_STATUS_CANCELLED;
}

LocalAgentStatus local_agent_backend_release_stream(LocalAgentBackendStream *stream) {
    if (stream == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    delete stream;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_release(LocalAgentBackend *backend) {
    if (backend == nullptr) {
        return LOCAL_AGENT_STATUS_INVALID_ARGUMENT;
    }
    delete backend;
    return LOCAL_AGENT_STATUS_OK;
}

LocalAgentStatus local_agent_backend_stream_chat(LocalAgentBackend *backend, const char *prompt_json, local_agent_token_callback callback, void *user_data, LocalAgentBackendStream **out_stream) {
    LocalAgentStatus start = local_agent_backend_start_chat(backend, prompt_json, out_stream);
    if (start != LOCAL_AGENT_STATUS_OK) {
        return start;
    }
    return local_agent_backend_read_stream(*out_stream, callback, user_data);
}

}
```

- [ ] **Step 6: Run test**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 \
  -I inference/include -I inference/core -I inference/backends/mock \
  inference/tests/c_api_backend_contract.cpp \
  inference/c_api/local_agent_inference.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o /tmp/c_api_backend_contract
/tmp/c_api_backend_contract
```

Expected: PASS with exit code 0.

- [ ] **Step 7: Update Rust build script source list**

Modify `local-ios-agent/rust-core/build.rs` so the mock local inference feature compiles:

```text
inference/c_api/local_agent_inference.cpp
inference/core/model_config.cpp
inference/core/token_stream.cpp
inference/backends/mock/mock_inference_engine.cpp
```

The archive name stays `local_agent_inference_mock` for compatibility.

- [ ] **Step 8: Run Rust linked mock test**

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --features link-mock-local-inference \
  --test local_llm_provider
```

Expected: existing C ABI-backed tests pass.

- [ ] **Step 9: Commit**

```bash
git add local-ios-agent/inference/include/local_agent_inference.h \
  local-ios-agent/inference/c_api/local_agent_inference.cpp \
  local-ios-agent/inference/backends/mock/mock_inference_engine.h \
  local-ios-agent/inference/backends/mock/mock_inference_engine.cpp \
  local-ios-agent/inference/tests/c_api_backend_contract.cpp \
  local-ios-agent/rust-core/build.rs
git commit -m "Refactor inference C ABI onto backend interface"
```

## Task 5: Add Rust Local LLM Provider Without Model-Specific Names

**Files:**
- Create: `local-ios-agent/rust-core/src/core/local_llm.rs`
- Delete: `local-ios-agent/rust-core/src/core/ondevice_minicpm.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`
- Create: `local-ios-agent/rust-core/tests/local_llm_provider.rs`

- [ ] **Step 1: Write failing provider naming test**

Create `local-ios-agent/rust-core/tests/local_llm_provider.rs`:

```rust
use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    LocalLLMProvider, MockLocalInferenceBackend, ModelProvider, ModelProviderOutput,
    CancellationToken,
};

#[test]
fn local_llm_provider_is_model_agnostic() {
    let backend = MockLocalInferenceBackend::new([
        r#"{"type":"text_delta","text":"local "}"#,
        r#"{"type":"completed","text":"local answer"}"#,
    ]);
    let provider = LocalLLMProvider::new(
        "local.gguf.simulator",
        r#"{"backend":"mock","model_path":"/tmp/mock.gguf"}"#,
        Box::new(backend),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        messages: vec![PromptMessage::User("hello".into())],
    };

    let output = provider.stream_chat(&frame, CancellationToken::default()).unwrap();

    assert_eq!(provider.id(), "local_llm");
    assert_eq!(output, vec![
        ModelProviderOutput::TextDelta("local ".into()),
        ModelProviderOutput::Completed("local answer".into()),
    ]);
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml --test local_llm_provider
```

Expected: FAIL because `local_llm` module and `LocalLLMProvider` are not exported.

- [ ] **Step 3: Add generic provider type**

Create `local-ios-agent/rust-core/src/core/local_llm.rs`:

```rust
use crate::context::PromptFrame;
use crate::core::{
    build_openai_chat_request, parse_backend_token, CancellationToken, ModelProvider,
    ModelProviderOutput,
};
use crate::error::AgentError;
use std::sync::Mutex;

pub struct LocalLLMProvider {
    model: String,
    model_config_json: String,
    backend: Box<dyn LocalInferenceBackend>,
    model_loaded: Mutex<bool>,
}

impl LocalLLMProvider {
    pub fn new(
        model: impl Into<String>,
        model_config_json: impl Into<String>,
        backend: Box<dyn LocalInferenceBackend>,
    ) -> Self {
        Self {
            model: model.into(),
            model_config_json: model_config_json.into(),
            backend,
            model_loaded: Mutex::new(false),
        }
    }

    fn ensure_model_loaded(&self) -> Result<(), AgentError> {
        let mut loaded = self.model_loaded.lock().map_err(|_| {
            AgentError::Provider("local llm model load state is poisoned".into())
        })?;
        if !*loaded {
            self.backend.load_model(&self.model_config_json)?;
            *loaded = true;
        }
        Ok(())
    }
}

impl ModelProvider for LocalLLMProvider {
    fn id(&self) -> &str {
        "local_llm"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        self.ensure_model_loaded()?;
        let prompt = build_openai_chat_request(&self.model, frame);
        let mut output = Vec::new();
        self.backend.stream_chat(
            &prompt.to_string(),
            cancellation,
            &mut |token_json| {
                output.push(parse_backend_token(token_json)?);
                Ok(())
            },
        )?;
        Ok(output)
    }
}
```

Move `LocalInferenceBackend`, `CAbiLocalInferenceBackend`, `MockLocalInferenceBackend`, `LocalAgentStatus`, and related C ABI wrapper types into this file or into focused sibling files under `core/local_llm/`. Do not keep a public `OnDeviceMiniCPMProvider` alias.

- [ ] **Step 4: Export only model-neutral names**

Modify `local-ios-agent/rust-core/src/core/mod.rs` to export:

```rust
pub mod local_llm;

pub use local_llm::{
    CAbiFunctions, CAbiLocalAgentBackend, CAbiLocalAgentBackendStream,
    CAbiLocalInferenceBackend, CAbiTokenCallback, LocalAgentStatus, LocalInferenceBackend,
    LocalLLMProvider, MockLocalInferenceBackend,
};
```

- [ ] **Step 5: Remove the model-specific module**

Remove `local-ios-agent/rust-core/src/core/ondevice_minicpm.rs` after the generic `local_llm` module compiles:

```bash
rm local-ios-agent/rust-core/src/core/ondevice_minicpm.rs
rg -n "OnDeviceMiniCPM|ondevice_minicpm" local-ios-agent/rust-core/src local-ios-agent/rust-core/tests
```

Expected: `rg` exits with code 1 and no matches.

- [ ] **Step 6: Run tests**

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml --test local_llm_provider
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml --test ffi_bridge
```

Expected: both pass.

- [ ] **Step 7: Commit**

```bash
git add local-ios-agent/rust-core/src/core/local_llm.rs \
  local-ios-agent/rust-core/src/core/mod.rs \
  local-ios-agent/rust-core/tests/local_llm_provider.rs
git add -u local-ios-agent/rust-core/src/core
git commit -m "Generalize on-device provider as local llm"
```

## Task 6: Add Rust Bridge Configuration For local_llm Provider

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift`
- Modify: `local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift`
- Modify: `local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift`

- [ ] **Step 1: Write failing Swift configuration test**

Add to `RustRuntimeClientContractTests.swift`:

```swift
@Test
func rustRuntimeConfigurationEncodesLocalLLMProviderConfiguration() throws {
    let configuration = RustRuntimeConfiguration(
        systemPrompt: "configured system",
        runtimePolicy: "configured policy",
        providerId: "local_llm",
        store: .inMemory,
        providers: [
            .localLLM(
                model: "local.gguf.simulator",
                modelConfigJson: #"{"backend":"mock","model_path":"/tmp/mock.gguf"}"#,
                maxContextTokens: 2048
            )
        ]
    )

    let data = try JSONEncoder().encode(configuration)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let providers = try #require(object["providers"] as? [[String: Any]])
    let local = try #require(providers.first)

    #expect(object["provider_id"] as? String == "local_llm")
    #expect(local["kind"] as? String == "local_llm")
    #expect(local["model"] as? String == "local.gguf.simulator")
    #expect(local["model_config_json"] as? String == #"{"backend":"mock","model_path":"/tmp/mock.gguf"}"#)
    #expect(local["max_context_tokens"] as? Int == 2048)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --package-path local-ios-agent/toolkit --filter rustRuntimeConfigurationEncodesLocalLLMProviderConfiguration
```

Expected: FAIL because `.localLLM` does not exist.

- [ ] **Step 3: Add Swift DTO cases**

Modify `ProviderKindDTO` in `RuntimeDTOs.swift`:

```swift
case localLLM = "local_llm"
```

Modify `RustRuntimeProviderConfiguration` in `RustRuntimeClient.swift`:

```swift
case localLLM(model: String, modelConfigJson: String, maxContextTokens: Int)
```

Encode it as:

```swift
try container.encode("local_llm", forKey: .kind)
try container.encode(model, forKey: .model)
try container.encode(modelConfigJson, forKey: .modelConfigJson)
try container.encode(maxContextTokens, forKey: .maxContextTokens)
```

Add coding key:

```swift
case modelConfigJson = "model_config_json"
```

- [ ] **Step 4: Add Rust bridge config variant**

Modify `RuntimeProviderConfigJson` in `ffi_bridge.rs`:

```rust
#[serde(rename = "local_llm")]
LocalLlm {
    model: String,
    model_config_json: String,
    max_context_tokens: usize,
},
```

Add the model-neutral runtime provider kind if it does not already exist:

```rust
pub enum ProviderKind {
    Mock,
    LocalLlm,
}
```

Register it by building a provider registry entry with:

```rust
ProviderProfile {
    id: "local_llm".into(),
    display_name: "Local LLM".into(),
    kind: ProviderKind::LocalLlm,
    max_context_tokens: *max_context_tokens,
}
```

and a `ProviderBundle` containing `LocalLLMProvider::new(model.clone(), model_config_json.clone(), Box::new(CAbiLocalInferenceBackend::new()?))`.

If `CAbiLocalInferenceBackend::new()` is unavailable because the backend is not linked, surface the existing provider error instead of falling back to mock.

- [ ] **Step 5: Run bridge tests**

```bash
swift test --package-path local-ios-agent/toolkit
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml --test ffi_bridge
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/RuntimeDTOs.swift \
  local-ios-agent/toolkit/Sources/LocalAgentBridge/RustRuntimeClient.swift \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RuntimeDTOTests.swift \
  local-ios-agent/toolkit/Tests/LocalAgentBridgeTests/RustRuntimeClientContractTests.swift
git commit -m "Add local llm provider bridge configuration"
```

## Task 7: Add llama.cpp Backend Behind Engine Interface

**Files:**
- Create: `local-ios-agent/inference/backends/llama_cpp/llama_cpp_api.h`
- Create: `local-ios-agent/inference/backends/llama_cpp/llama_cpp_api.cpp`
- Create: `local-ios-agent/inference/backends/llama_cpp/llama_cpp_engine.h`
- Create: `local-ios-agent/inference/backends/llama_cpp/llama_cpp_engine.cpp`
- Test: `local-ios-agent/inference/tests/llama_cpp_backend_contract.cpp`
- Create: `local-ios-agent/scripts/build-llama-cpp-xcframework.sh`
- Modify: `local-ios-agent/rust-core/build.rs`
- Modify: `local-ios-agent/rust-core/Cargo.toml`

- [ ] **Step 1: Write failing backend contract test**

Create `local-ios-agent/inference/tests/llama_cpp_backend_contract.cpp`:

```cpp
#include "llama_cpp_engine.h"
#include "model_config.h"

#include <cassert>
#include <cstdlib>
#include <string>
#include <vector>

int main() {
    const char *model_path = std::getenv("LOCAL_AGENT_SIMULATOR_GGUF");
    if (model_path == nullptr || std::string(model_path).empty()) {
        return 77;
    }
    const char *mmproj_path_env = std::getenv("LOCAL_AGENT_SIMULATOR_MMPROJ");
    const std::string mmproj_path = mmproj_path_env == nullptr ? "" : mmproj_path_env;

    std::string config_json = std::string(R"({
      "backend":"llama_cpp",
      "model_id":"local.gguf.simulator",
      "model_path":")") + model_path + R"(",
      "chat_template":"gguf",
      "max_context_tokens":512,
      "generation":{"temperature":0.0,"top_p":1.0,"max_new_tokens":16,"seed":42},
      "llama_cpp":{"n_gpu_layers":0,"n_threads":2,"mmproj_path":")") + mmproj_path + R"("}
    })";

    local_agent::ModelConfig config = local_agent::parse_model_config(config_json.c_str());
    local_agent::LlamaCppEngine engine;
    engine.load(config);

    auto stream = engine.start_chat(R"({"messages":[{"role":"user","content":"Say hi."}]})");
    std::vector<std::string> tokens;
    engine.read_stream(*stream, [&](const std::string &token_json) {
        tokens.push_back(token_json);
    });

    assert(!tokens.empty());
    assert(tokens.back().find("\"type\":\"completed\"") != std::string::npos);

    if (!mmproj_path.empty()) {
        unsigned char white_pixel[3] = {255, 255, 255};
        auto image_stream = engine.start_chat_with_image(
            R"({"messages":[{"role":"user","content":"Describe this image."}]})",
            local_agent::ImageInput{std::vector<unsigned char>(white_pixel, white_pixel + 3), 1, 1}
        );
        std::vector<std::string> image_tokens;
        engine.read_stream(*image_stream, [&](const std::string &token_json) {
            image_tokens.push_back(token_json);
        });
        assert(!image_tokens.empty());
    }
    return 0;
}
```

Exit code 77 means the real model artifact is not configured; CI may skip this test, but local Plan 13 acceptance must run it with `LOCAL_AGENT_SIMULATOR_GGUF`.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 \
  -I inference/core -I inference/backends/llama_cpp \
  inference/tests/llama_cpp_backend_contract.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/llama_cpp/llama_cpp_api.cpp \
  inference/backends/llama_cpp/llama_cpp_engine.cpp \
  -o /tmp/llama_cpp_backend_contract
```

Expected: FAIL because llama.cpp backend files do not exist.

- [ ] **Step 3: Add llama.cpp build script**

Create `local-ios-agent/scripts/build-llama-cpp-xcframework.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$ROOT/third_party/llama.cpp}"

if [[ ! -f "$LLAMA_CPP_DIR/build-xcframework.sh" ]]; then
  echo "Missing llama.cpp checkout at $LLAMA_CPP_DIR" >&2
  echo "Clone ggml-org/llama.cpp there, pin the revision in docs/model-providers/simulator-llamacpp-contract.md, then rerun." >&2
  exit 2
fi

(
  cd "$LLAMA_CPP_DIR"
  ./build-xcframework.sh
)

test -d "$LLAMA_CPP_DIR/build-apple/llama.xcframework"
echo "$LLAMA_CPP_DIR/build-apple/llama.xcframework"
```

- [ ] **Step 4: Add llama API shim**

Create `llama_cpp_api.h` as the only file that includes upstream llama.cpp headers:

```cpp
#ifndef LOCAL_AGENT_LLAMA_CPP_API_H
#define LOCAL_AGENT_LLAMA_CPP_API_H

#include "model_config.h"

#include <functional>
#include <memory>
#include <string>

namespace local_agent {

using LlamaTokenEmit = std::function<void(const std::string &)>;
struct ImageInput;

class LlamaCppSession {
public:
    virtual ~LlamaCppSession() = default;
    virtual void load(const ModelConfig &config) = 0;
    virtual void stream_generate(
        const std::string &prompt_json,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) = 0;
    virtual void stream_generate_with_image(
        const std::string &prompt_json,
        const ImageInput &image,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) = 0;
};

std::unique_ptr<LlamaCppSession> make_llama_cpp_session();

} // namespace local_agent

#endif
```

Create `llama_cpp_api.cpp`:

```cpp
#include "llama_cpp_api.h"
#include "inference_engine.h"

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
#include "llama.h"
#endif

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
#include "mtmd.h"
#endif

#include <stdexcept>
#include <string>
#include <vector>

namespace local_agent {

namespace {

class UnavailableLlamaCppSession final : public LlamaCppSession {
public:
    void load(const ModelConfig &) override {
        throw std::runtime_error("llama.cpp backend is not linked in this build");
    }
    void stream_generate(const std::string &, const ModelConfig &, const LlamaTokenEmit &) override {
        throw std::runtime_error("llama.cpp backend is not linked in this build");
    }
    void stream_generate_with_image(const std::string &, const ImageInput &, const ModelConfig &, const LlamaTokenEmit &) override {
        throw std::runtime_error("llama.cpp multimodal backend is not linked in this build");
    }
};

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
class LinkedLlamaCppSession final : public LlamaCppSession {
public:
    ~LinkedLlamaCppSession() override {
        release();
    }

    void load(const ModelConfig &config) override {
        if (config.model_path.empty()) {
            throw std::invalid_argument("llama.cpp model_path is empty");
        }

        release();
        llama_backend_init();

        llama_model_params model_params = llama_model_default_params();
        model_params.n_gpu_layers = config.llama_cpp.n_gpu_layers;
        model_ = llama_model_load_from_file(config.model_path.c_str(), model_params);
        if (model_ == nullptr) {
            throw std::runtime_error("llama.cpp failed to load model: " + config.model_path);
        }

        llama_context_params context_params = llama_context_default_params();
        context_params.n_ctx = static_cast<uint32_t>(config.max_context_tokens);
        context_params.n_threads = config.llama_cpp.n_threads;
        context_params.n_threads_batch = config.llama_cpp.n_threads;
        context_ = llama_init_from_model(model_, context_params);
        if (context_ == nullptr) {
            throw std::runtime_error("llama.cpp failed to create context");
        }

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
        if (!config.llama_cpp.mmproj_path.empty()) {
            mtmd_context_params mtmd_params = mtmd_context_params_default();
            mtmd_params.n_threads = config.llama_cpp.n_threads;
            mtmd_ = mtmd_init_from_file(config.llama_cpp.mmproj_path.c_str(), model_, mtmd_params);
            if (mtmd_ == nullptr) {
                throw std::runtime_error("llama.cpp failed to load mmproj: " + config.llama_cpp.mmproj_path);
            }
        }
#endif
    }

    void stream_generate(
        const std::string &prompt_json,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) override {
        if (model_ == nullptr || context_ == nullptr) {
            throw std::runtime_error("llama.cpp model is not loaded");
        }

        // First implementation may use the simplest llama.cpp tokenization and
        // greedy sampling path copied from the current upstream examples. Keep
        // every upstream API call inside this file so future llama.cpp API churn
        // does not leak into C ABI, Rust, or Swift.
        run_llama_generation(prompt_json, config, emit);
    }

    void stream_generate_with_image(
        const std::string &prompt_json,
        const ImageInput &image,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) override {
        if (model_ == nullptr || context_ == nullptr) {
            throw std::runtime_error("llama.cpp model is not loaded");
        }
        if (config.llama_cpp.mmproj_path.empty()) {
            throw std::invalid_argument("llama.cpp mmproj_path is required for image input");
        }
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
        run_mtmd_prefill(prompt_json, image, config);
        sample_from_context(config, emit);
#else
        throw std::runtime_error("llama.cpp mtmd backend is not linked in this build");
#endif
    }

private:
    llama_model *model_ = nullptr;
    llama_context *context_ = nullptr;
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
    mtmd_context *mtmd_ = nullptr;
#endif

    void release() {
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
        if (mtmd_ != nullptr) {
            mtmd_free(mtmd_);
            mtmd_ = nullptr;
        }
#endif
        if (context_ != nullptr) {
            llama_free(context_);
            context_ = nullptr;
        }
        if (model_ != nullptr) {
            llama_model_free(model_);
            model_ = nullptr;
        }
    }

    void run_llama_generation(
        const std::string &prompt_json,
        const ModelConfig &config,
        const LlamaTokenEmit &emit
    ) {
        const llama_vocab *vocab = llama_model_get_vocab(model_);
        if (vocab == nullptr) {
            throw std::runtime_error("llama.cpp model has no vocabulary");
        }

        const std::string prompt = prompt_json;
        int prompt_token_count = -llama_tokenize(
            vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.size()),
            nullptr,
            0,
            true,
            true
        );
        if (prompt_token_count <= 0) {
            throw std::runtime_error("llama.cpp failed to count prompt tokens");
        }

        std::vector<llama_token> prompt_tokens(static_cast<size_t>(prompt_token_count));
        int actual_prompt_tokens = llama_tokenize(
            vocab,
            prompt.c_str(),
            static_cast<int32_t>(prompt.size()),
            prompt_tokens.data(),
            static_cast<int32_t>(prompt_tokens.size()),
            true,
            true
        );
        if (actual_prompt_tokens < 0) {
            throw std::runtime_error("llama.cpp failed to tokenize prompt");
        }
        prompt_tokens.resize(static_cast<size_t>(actual_prompt_tokens));

        llama_batch prompt_batch = llama_batch_get_one(
            prompt_tokens.data(),
            static_cast<int32_t>(prompt_tokens.size())
        );
        if (llama_decode(context_, prompt_batch) != 0) {
            throw std::runtime_error("llama.cpp failed to decode prompt");
        }

        sample_from_context(config, emit);
    }

    void sample_from_context(const ModelConfig &config, const LlamaTokenEmit &emit) {
        const llama_vocab *vocab = llama_model_get_vocab(model_);
        if (vocab == nullptr) {
            throw std::runtime_error("llama.cpp model has no vocabulary");
        }

        llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(config.generation.temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(static_cast<uint32_t>(config.generation.seed)));

        for (int i = 0; i < config.generation.max_new_tokens; i += 1) {
            llama_token token = llama_sampler_sample(sampler, context_, -1);
            if (llama_vocab_is_eog(vocab, token)) {
                break;
            }

            char piece[512];
            int piece_size = llama_token_to_piece(
                vocab,
                token,
                piece,
                sizeof(piece),
                0,
                true
            );
            if (piece_size > 0) {
                emit(std::string(piece, static_cast<size_t>(piece_size)));
            }

            llama_batch next_batch = llama_batch_get_one(&token, 1);
            if (llama_decode(context_, next_batch) != 0) {
                llama_sampler_free(sampler);
                throw std::runtime_error("llama.cpp failed to decode generated token");
            }
        }

        llama_sampler_free(sampler);
    }

#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD)
    void run_mtmd_prefill(const std::string &prompt_json, const ImageInput &image, const ModelConfig &) {
        if (mtmd_ == nullptr) {
            throw std::runtime_error("llama.cpp mtmd context is not loaded");
        }
        if (image.rgb_data.size() != static_cast<size_t>(image.width) * static_cast<size_t>(image.height) * 3) {
            throw std::invalid_argument("image RGB buffer size does not match width and height");
        }

        mtmd_bitmap *bitmap = mtmd_bitmap_init(image.width, image.height, image.rgb_data.data());
        if (bitmap == nullptr) {
            throw std::runtime_error("llama.cpp failed to create mtmd bitmap");
        }

        mtmd_input_chunks *chunks = mtmd_input_chunks_init();
        if (chunks == nullptr) {
            mtmd_bitmap_free(bitmap);
            throw std::runtime_error("llama.cpp failed to create mtmd input chunks");
        }

        const mtmd_bitmap *bitmaps[1] = {bitmap};
        int32_t tokenize_status = mtmd_tokenize(mtmd_, chunks, prompt_json.c_str(), bitmaps, 1);
        if (tokenize_status != 0) {
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bitmap);
            throw std::runtime_error("llama.cpp mtmd_tokenize failed");
        }

        llama_pos n_past = 0;
        int32_t eval_status = mtmd_helper_eval_chunks(mtmd_, context_, chunks, n_past, 0, 512, true, &n_past);
        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bitmap);
        if (eval_status != 0) {
            throw std::runtime_error("llama.cpp mtmd chunk evaluation failed");
        }
    }
#endif
};
#endif

} // namespace

std::unique_ptr<LlamaCppSession> make_llama_cpp_session() {
#if defined(LOCAL_AGENT_ENABLE_LLAMA_CPP)
    return std::make_unique<LinkedLlamaCppSession>();
#else
    return std::make_unique<UnavailableLlamaCppSession>();
#endif
}

} // namespace local_agent
```

The linked implementation is not allowed to return deterministic fake text. `UnavailableLlamaCppSession` may fail clearly when the backend is not linked; `LinkedLlamaCppSession` must call the pinned llama.cpp `include/llama.h` API before the real backend contract can pass. Multimodal builds must call the pinned `mtmd.h` API through this same file. If the pinned llama.cpp revision changes function names, adapt only `llama_cpp_api.cpp`.

- [ ] **Step 5: Add llama.cpp engine**

Create `llama_cpp_engine.h`:

```cpp
#ifndef LOCAL_AGENT_LLAMA_CPP_ENGINE_H
#define LOCAL_AGENT_LLAMA_CPP_ENGINE_H

#include "inference_engine.h"
#include "llama_cpp_api.h"

namespace local_agent {

class LlamaCppEngine final : public InferenceEngine {
public:
    LlamaCppEngine();
    void load(const ModelConfig &config) override;
    std::unique_ptr<TokenStream> start_chat(const std::string &prompt_json) override;
    std::unique_ptr<TokenStream> start_chat_with_image(
        const std::string &prompt_json,
        const ImageInput &image
    ) override;
    void read_stream(TokenStream &stream, const TokenStream::Emit &emit) override;

private:
    ModelConfig config_;
    std::string prompt_json_;
    ImageInput image_;
    bool has_image_ = false;
    std::unique_ptr<LlamaCppSession> session_;
};

} // namespace local_agent

#endif
```

Create `llama_cpp_engine.cpp`:

```cpp
#include "llama_cpp_engine.h"

#include <stdexcept>

namespace local_agent {

LlamaCppEngine::LlamaCppEngine()
    : session_(make_llama_cpp_session()) {}

void LlamaCppEngine::load(const ModelConfig &config) {
    if (config.backend != "llama_cpp") {
        throw std::invalid_argument("LlamaCppEngine requires backend=llama_cpp");
    }
    config_ = config;
    session_->load(config_);
}

std::unique_ptr<TokenStream> LlamaCppEngine::start_chat(const std::string &prompt_json) {
    if (prompt_json.empty()) {
        throw std::invalid_argument("prompt json must not be empty");
    }
    prompt_json_ = prompt_json;
    image_ = ImageInput();
    has_image_ = false;
    return std::make_unique<TokenStream>();
}

std::unique_ptr<TokenStream> LlamaCppEngine::start_chat_with_image(
    const std::string &prompt_json,
    const ImageInput &image
) {
    if (prompt_json.empty()) {
        throw std::invalid_argument("prompt json must not be empty");
    }
    if (image.rgb_data.empty() || image.width == 0 || image.height == 0) {
        throw std::invalid_argument("image input must contain RGB bytes and dimensions");
    }
    prompt_json_ = prompt_json;
    image_ = image;
    has_image_ = true;
    return std::make_unique<TokenStream>();
}

void LlamaCppEngine::read_stream(TokenStream &stream, const TokenStream::Emit &emit) {
    std::string completed;
    auto on_delta = [&](const std::string &delta) {
        if (stream.is_cancelled()) {
            return;
        }
        completed += delta;
        stream.emit_text_delta(delta, emit);
    };
    if (has_image_) {
        session_->stream_generate_with_image(prompt_json_, image_, config_, on_delta);
    } else {
        session_->stream_generate(prompt_json_, config_, on_delta);
    }
    if (!stream.is_cancelled()) {
        stream.emit_completed(completed, emit);
    }
}

} // namespace local_agent
```

- [ ] **Step 6: Wire factory without changing C ABI**

Modify `make_inference_engine` in `inference/c_api/local_agent_inference.cpp`:

```cpp
if (config.backend == "llama_cpp") {
    return std::make_unique<local_agent::LlamaCppEngine>();
}
```

Keep `backend=mock` unchanged.

- [ ] **Step 7: Add feature flags**

Modify `Cargo.toml`:

```toml
[features]
default = []
link-mock-local-inference = []
link-llama-cpp-local-inference = ["link-mock-local-inference"]
link-llama-cpp-mtmd-local-inference = ["link-llama-cpp-local-inference"]
```

Modify `build.rs`:

- Compile llama.cpp backend sources when `CARGO_FEATURE_LINK_LLAMA_CPP_LOCAL_INFERENCE` is set.
- Add `-DLOCAL_AGENT_ENABLE_LLAMA_CPP`.
- Link the XCFramework/static library path from `LLAMA_CPP_XCFRAMEWORK`.
- When `CARGO_FEATURE_LINK_LLAMA_CPP_MTMD_LOCAL_INFERENCE` is set, add `-DLOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD`, add the mtmd include path from `LLAMA_CPP_MTMD_HEADERS`, and link the mtmd/static-library artifact from `LLAMA_CPP_MTMD_LIBRARY`.

- [ ] **Step 8: Run mock and optional real tests**

Mock:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --features link-mock-local-inference \
  --test local_llm_provider
```

Real local llama.cpp, only after `LOCAL_AGENT_SIMULATOR_GGUF` and `LLAMA_CPP_XCFRAMEWORK` are set:

```bash
LOCAL_AGENT_SIMULATOR_GGUF="$LOCAL_AGENT_SIMULATOR_GGUF" \
clang++ -std=c++17 \
  -DLOCAL_AGENT_ENABLE_LLAMA_CPP \
  -I inference/core -I inference/backends/llama_cpp \
  -I "$LLAMA_CPP_HEADERS" \
  inference/tests/llama_cpp_backend_contract.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/llama_cpp/llama_cpp_api.cpp \
  inference/backends/llama_cpp/llama_cpp_engine.cpp \
  -o /tmp/llama_cpp_backend_contract
/tmp/llama_cpp_backend_contract
```

Real local multimodal path, only after `LOCAL_AGENT_SIMULATOR_MMPROJ`, `LLAMA_CPP_MTMD_HEADERS`, and `LLAMA_CPP_MTMD_LIBRARY` are set:

```bash
LOCAL_AGENT_SIMULATOR_GGUF="$LOCAL_AGENT_SIMULATOR_GGUF" \
LOCAL_AGENT_SIMULATOR_MMPROJ="$LOCAL_AGENT_SIMULATOR_MMPROJ" \
clang++ -std=c++17 \
  -DLOCAL_AGENT_ENABLE_LLAMA_CPP \
  -DLOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD \
  -I inference/core -I inference/backends/llama_cpp \
  -I "$LLAMA_CPP_HEADERS" \
  -I "$LLAMA_CPP_MTMD_HEADERS" \
  inference/tests/llama_cpp_backend_contract.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/llama_cpp/llama_cpp_api.cpp \
  inference/backends/llama_cpp/llama_cpp_engine.cpp \
  "$LLAMA_CPP_MTMD_LIBRARY" \
  -o /tmp/llama_cpp_backend_contract
/tmp/llama_cpp_backend_contract
```

Expected: mock test always passes; real text test passes locally or exits 77 when no model is configured; real multimodal test passes only when model, mmproj, mtmd headers, and mtmd library match the pinned llama.cpp revision.

- [ ] **Step 9: Commit**

```bash
git add local-ios-agent/inference/backends/llama_cpp \
  local-ios-agent/inference/tests/llama_cpp_backend_contract.cpp \
  local-ios-agent/scripts/build-llama-cpp-xcframework.sh \
  local-ios-agent/rust-core/build.rs \
  local-ios-agent/rust-core/Cargo.toml
git commit -m "Add llama cpp backend behind inference interface"
```

## Task 8: Add Swift LLM Protocol And Objective-C++ Anti-Corruption Bridge

**Files:**
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain/StructuredOutput.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain/LLMEngineProtocol.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Infrastructure/NativeInference/NativeLlamaEngineAdapter.swift`
- Create: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Domain/LLMEngineProtocolTests.swift`
- Create: `local-ios-agent/inference/objc_bridge/LlamaBridge.h`
- Create: `local-ios-agent/inference/objc_bridge/LlamaBridge.mm`
- Test: `local-ios-agent/inference/tests/objc_bridge_header_contract.m`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing Swift protocol test**

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Domain/LLMEngineProtocolTests.swift`:

```swift
import Testing
import UIKit
@testable import LocalAgentApp

private struct EchoOutput: StructuredOutput, Equatable {
    let value: String
}

private struct ScriptedLLMEngine: LLMEngineProtocol {
    func stream(prompt: String, image: UIImage?) -> AsyncThrowingStream<LLMTokenEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(#"{"value":"#))
            continuation.yield(.textDelta(prompt))
            continuation.yield(.textDelta(#""}"#))
            continuation.yield(.completed(#"{"value":"\#(prompt)"}"#))
            continuation.finish()
        }
    }
}

@Test("LLMEngineProtocol predicts structured output without backend types")
func llmEngineProtocolPredictsStructuredOutput() async throws {
    let engine = ScriptedLLMEngine()

    let output = try await engine.predict(prompt: "hello", image: nil, as: EchoOutput.self)

    #expect(output == EchoOutput(value: "hello"))
}
```

- [ ] **Step 2: Run Swift test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/LLMEngineProtocolTests test
```

Expected: FAIL because `StructuredOutput`, `LLMTokenEvent`, and `LLMEngineProtocol` do not exist.

- [ ] **Step 3: Add Swift domain protocol**

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain/StructuredOutput.swift`:

```swift
import Foundation

protocol StructuredOutput: Decodable, Sendable {}
```

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain/LLMEngineProtocol.swift`:

```swift
import Foundation
import UIKit

enum LLMTokenEvent: Equatable, Sendable {
    case textDelta(String)
    case completed(String)
}

protocol LLMEngineProtocol: Sendable {
    func stream(prompt: String, image: UIImage?) -> AsyncThrowingStream<LLMTokenEvent, Error>
    func predict<T: StructuredOutput>(prompt: String, image: UIImage?, as type: T.Type) async throws -> T
}

extension LLMEngineProtocol {
    func predict<T: StructuredOutput>(prompt: String, image: UIImage?, as type: T.Type) async throws -> T {
        var completedText: String?
        var accumulated = ""

        for try await event in stream(prompt: prompt, image: image) {
            switch event {
            case .textDelta(let text):
                accumulated += text
            case .completed(let text):
                completedText = text
            }
        }

        let jsonText = completedText ?? accumulated
        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

Do not import `LlamaBridge`, C ABI headers, or C++ headers in either domain file.

- [ ] **Step 4: Write Objective-C header cleanliness test**

Create `local-ios-agent/inference/tests/objc_bridge_header_contract.m`:

```objective-c
#import "LlamaBridge.h"

int main(void) {
    LALlamaBridge *bridge = nil;
    (void)bridge;
    return 0;
}
```

- [ ] **Step 5: Run header test to verify it fails**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang -fobjc-arc -x objective-c \
  -isysroot "$SDKROOT" \
  -I inference/objc_bridge \
  -c inference/tests/objc_bridge_header_contract.m \
  -o /tmp/objc_bridge_header_contract.o
```

Expected: FAIL because `LlamaBridge.h` does not exist.

- [ ] **Step 6: Add Swift-safe Objective-C bridge header**

Create `local-ios-agent/inference/objc_bridge/LlamaBridge.h`:

```objective-c
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LALlamaTokenHandler)(NSString *tokenJSON);
typedef void (^LALlamaCompletionHandler)(NSError *_Nullable error);

NS_SWIFT_NAME(LlamaBridge)
@interface LALlamaBridge : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithModelConfigJSON:(NSString *)modelConfigJSON
                                  error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (void)predictWithPromptJSON:(NSString *)promptJSON
                        image:(nullable UIImage *)image
                      onToken:(LALlamaTokenHandler)onToken
                   completion:(LALlamaCompletionHandler)completion;

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
```

Header contract:

- No `#include <vector>`.
- No `#include <string>`.
- No `#include <memory>`.
- No `#include "llama.h"`.
- No `#include "mtmd.h"`.
- No project C++ headers.
- No raw backend pointer types in public method signatures.

- [ ] **Step 7: Add Objective-C++ bridge implementation**

Create `local-ios-agent/inference/objc_bridge/LlamaBridge.mm`:

```objective-c++
#import "LlamaBridge.h"

#include "local_agent_inference.h"

#import <CoreGraphics/CoreGraphics.h>

static NSString *const LALlamaBridgeErrorDomain = @"LocalAgent.LlamaBridge";

typedef NS_ENUM(NSInteger, LALlamaBridgeErrorCode) {
    LALlamaBridgeErrorInvalidArgument = 1,
    LALlamaBridgeErrorBackendFailure = 2,
    LALlamaBridgeErrorUnsupportedImage = 3,
};

@interface LAStreamContext : NSObject
@property(nonatomic, copy) LALlamaTokenHandler onToken;
@end

@implementation LAStreamContext
@end

@interface LALlamaBridge ()
@property(nonatomic, assign) LocalAgentBackend *backend;
@property(nonatomic, assign) LocalAgentBackendStream *activeStream;
@end

static NSError *LAError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LALlamaBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSError *LAErrorFromStatus(LocalAgentStatus status, NSString *operation) {
    if (status == LOCAL_AGENT_STATUS_OK) {
        return nil;
    }
    if (status == LOCAL_AGENT_STATUS_INVALID_ARGUMENT) {
        return LAError(LALlamaBridgeErrorInvalidArgument, [operation stringByAppendingString:@" rejected invalid input"]);
    }
    if (status == LOCAL_AGENT_STATUS_CANCELLED) {
        return LAError(NSUserCancelledError, [operation stringByAppendingString:@" cancelled"]);
    }
    return LAError(LALlamaBridgeErrorBackendFailure, [operation stringByAppendingString:@" failed"]);
}

static NSData *LARGBDataFromImage(UIImage *image, NSUInteger *widthOut, NSUInteger *heightOut, NSError **error) {
    CGImageRef cgImage = image.CGImage;
    if (cgImage == nil) {
        if (error != nil) {
            *error = LAError(LALlamaBridgeErrorInvalidArgument, @"image does not contain CGImage data");
        }
        return nil;
    }

    const size_t width = CGImageGetWidth(cgImage);
    const size_t height = CGImageGetHeight(cgImage);
    NSMutableData *rgbaData = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        rgbaData.mutableBytes,
        width,
        height,
        8,
        width * 4,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);

    if (context == nil) {
        if (error != nil) {
            *error = LAError(LALlamaBridgeErrorBackendFailure, @"failed to create image conversion context");
        }
        return nil;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);

    NSMutableData *rgbData = [NSMutableData dataWithLength:width * height * 3];
    const unsigned char *rgba = static_cast<const unsigned char *>(rgbaData.bytes);
    unsigned char *rgb = static_cast<unsigned char *>(rgbData.mutableBytes);
    for (size_t pixel = 0; pixel < width * height; pixel += 1) {
        rgb[pixel * 3 + 0] = rgba[pixel * 4 + 0];
        rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1];
        rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2];
    }

    *widthOut = width;
    *heightOut = height;
    return rgbData;
}

static void LATokenCallback(const char *token_json, void *user_data) {
    if (token_json == nullptr || user_data == nullptr) {
        return;
    }
    LAStreamContext *context = (__bridge LAStreamContext *)user_data;
    NSString *token = [NSString stringWithUTF8String:token_json];
    if (token != nil) {
        context.onToken(token);
    }
}

@implementation LALlamaBridge

- (instancetype)initWithModelConfigJSON:(NSString *)modelConfigJSON error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    LocalAgentBackend *backend = nullptr;
    LocalAgentStatus initStatus = local_agent_backend_init(&backend);
    NSError *initError = LAErrorFromStatus(initStatus, @"initialize native inference backend");
    if (initError != nil) {
        if (error != nil) {
            *error = initError;
        }
        return nil;
    }

    LocalAgentStatus loadStatus = local_agent_backend_load_model(backend, modelConfigJSON.UTF8String);
    NSError *loadError = LAErrorFromStatus(loadStatus, @"load native inference model");
    if (loadError != nil) {
        local_agent_backend_release(backend);
        if (error != nil) {
            *error = loadError;
        }
        return nil;
    }

    _backend = backend;
    return self;
}

- (void)predictWithPromptJSON:(NSString *)promptJSON
                        image:(UIImage *)image
                      onToken:(LALlamaTokenHandler)onToken
                   completion:(LALlamaCompletionHandler)completion {
    if (self.backend == nullptr) {
        completion(LAError(LALlamaBridgeErrorBackendFailure, @"native inference backend is not initialized"));
        return;
    }
    if (promptJSON.length == 0) {
        completion(LAError(LALlamaBridgeErrorInvalidArgument, @"prompt JSON must not be empty"));
        return;
    }
    NSUInteger imageWidth = 0;
    NSUInteger imageHeight = 0;
    NSData *rgbData = nil;
    if (image != nil) {
        NSError *imageError = nil;
        rgbData = LARGBDataFromImage(image, &imageWidth, &imageHeight, &imageError);
        if (rgbData == nil) {
            completion(imageError);
            return;
        }
    }

    LAStreamContext *context = [LAStreamContext new];
    context.onToken = onToken;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LocalAgentBackendStream *stream = nullptr;
        LocalAgentStatus startStatus = LOCAL_AGENT_STATUS_ERROR;
        if (rgbData != nil) {
            startStatus = local_agent_backend_start_chat_with_image(
                self.backend,
                promptJSON.UTF8String,
                static_cast<const unsigned char *>(rgbData.bytes),
                static_cast<uint32_t>(imageWidth),
                static_cast<uint32_t>(imageHeight),
                &stream
            );
        } else {
            startStatus = local_agent_backend_start_chat(self.backend, promptJSON.UTF8String, &stream);
        }
        NSError *startError = LAErrorFromStatus(startStatus, @"start native inference stream");
        if (startError != nil) {
            completion(startError);
            return;
        }

        self.activeStream = stream;
        LocalAgentStatus readStatus = local_agent_backend_read_stream(stream, LATokenCallback, (__bridge void *)context);
        LocalAgentStatus releaseStatus = local_agent_backend_release_stream(stream);
        self.activeStream = nullptr;

        NSError *readError = LAErrorFromStatus(readStatus, @"read native inference stream");
        if (readError != nil) {
            completion(readError);
            return;
        }

        completion(LAErrorFromStatus(releaseStatus, @"release native inference stream"));
    });
}

- (void)cancel {
    LocalAgentBackendStream *stream = self.activeStream;
    if (stream != nullptr) {
        local_agent_backend_cancel(stream);
    }
}

- (void)dealloc {
    if (_activeStream != nullptr) {
        local_agent_backend_cancel(_activeStream);
        local_agent_backend_release_stream(_activeStream);
        _activeStream = nullptr;
    }
    if (_backend != nullptr) {
        local_agent_backend_release(_backend);
        _backend = nullptr;
    }
}

@end
```

The implementation may use Objective-C++, C ABI, CoreGraphics, and private C++ helpers. Its public header stays Swift-safe.

- [ ] **Step 8: Add native Swift adapter**

Create `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Infrastructure/NativeInference/NativeLlamaEngineAdapter.swift`:

```swift
import Foundation
import UIKit

final class NativeLlamaEngineAdapter: LLMEngineProtocol, @unchecked Sendable {
    private let bridge: LlamaBridge

    init(modelConfigJSON: String) throws {
        var error: NSError?
        guard let bridge = LlamaBridge(modelConfigJSON: modelConfigJSON, error: &error) else {
            throw error ?? NSError(domain: "LocalAgent.NativeLlamaEngineAdapter", code: 1)
        }
        self.bridge = bridge
    }

    func stream(prompt: String, image: UIImage?) -> AsyncThrowingStream<LLMTokenEvent, Error> {
        AsyncThrowingStream { continuation in
            let promptJSON = #"{"messages":[{"role":"user","content":"\#(prompt)"}]}"#
            bridge.predict(
                withPromptJSON: promptJSON,
                image: image,
                onToken: { tokenJSON in
                    if tokenJSON.contains(#""type":"completed""#) {
                        continuation.yield(.completed(tokenJSON))
                    } else {
                        continuation.yield(.textDelta(tokenJSON))
                    }
                },
                completion: { error in
                    if let error {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            )
        }
    }
}
```

`NativeLlamaEngineAdapter` is an infrastructure adapter. `AgentViewModel`, `ChatView`, reducers, and tool drivers must not import it directly; composition owns injection.

- [ ] **Step 9: Verify no Swift UI layer imports the bridge**

Run:

```bash
rg -n "LlamaBridge|NativeLlamaEngineAdapter|llama|LocalAgentBackend" \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Tools
```

Expected: no matches.

- [ ] **Step 10: Run tests**

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang -fobjc-arc -x objective-c \
  -isysroot "$SDKROOT" \
  -I inference/objc_bridge \
  -c inference/tests/objc_bridge_header_contract.m \
  -o /tmp/objc_bridge_header_contract.o

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/LLMEngineProtocolTests test
```

Expected: both pass.

- [ ] **Step 11: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Domain \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Infrastructure/NativeInference \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Domain \
  local-ios-agent/inference/objc_bridge \
  local-ios-agent/inference/tests/objc_bridge_header_contract.m \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git commit -m "Add Swift local llm engine boundary"
```

## Task 9: Wire Simulator App To local_llm Provider

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift`
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift`

- [ ] **Step 1: Write failing service test for provider loading**

Add to `AgentRuntimeServiceTests.swift`:

```swift
@Test("prepare loads provider profiles and active provider")
func prepareLoadsProviderProfilesAndActiveProvider() async throws {
    let client = ScriptedRuntimeClient()
    await client.setProviderProfilesForTest([
        ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096),
        ProviderProfileDTO(id: "local_llm", displayName: "Local LLM", kind: .localLLM, maxContextTokens: 2048),
    ])
    await client.setActiveProviderForTest(
        ProviderProfileDTO(id: "mock", displayName: "Mock", kind: .mock, maxContextTokens: 4096)
    )
    let service = AgentRuntimeService(runtimeClient: client, toolDriver: MinimalHostToolDriver())

    let state = try await service.prepare()

    #expect(state.provider.profiles.map(\.id) == ["mock", "local_llm"])
    #expect(state.provider.active?.id == "mock")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:LocalAgentAppTests/AgentRuntimeServiceTests test
```

Expected: FAIL because `AgentViewState.provider` and provider test helpers do not exist.

- [ ] **Step 3: Add provider state**

Modify `AgentViewState.swift`:

```swift
struct ProviderSelectionViewState: Equatable, Sendable {
    var profiles: [ProviderProfileDTO]
    var active: ProviderProfileDTO?
    var errorMessage: String?

    init(
        profiles: [ProviderProfileDTO] = [],
        active: ProviderProfileDTO? = nil,
        errorMessage: String? = nil
    ) {
        self.profiles = profiles
        self.active = active
        self.errorMessage = errorMessage
    }
}
```

Add to `AgentViewState`:

```swift
var provider: ProviderSelectionViewState
```

and initializer default:

```swift
provider: ProviderSelectionViewState = ProviderSelectionViewState()
```

- [ ] **Step 4: Add service provider methods without leaking C++**

Modify `AgentRuntimeServicing`:

```swift
func selectProvider(_ providerId: String, state: AgentViewState) async throws -> AgentViewState
```

In `prepare()`, if `runtimeClient as? any ProviderControllingRuntimeClient` succeeds, load:

```swift
let profiles = try await providerClient.providerProfiles()
let active = try await providerClient.activeProvider()
state.provider = ProviderSelectionViewState(profiles: profiles, active: active)
```

In `selectProvider`, reject running state:

```swift
guard !state.phase.isRunning else {
    throw AgentRuntimeServiceError.duplicateRun
}
```

Call `setProvider(sessionId: providerId:)`, reduce the returned event, then refresh active provider.

- [ ] **Step 5: Configure AppBootstrapper for local_llm**

Modify `AppBootstrapper.makeContainer()` so the simulator config includes local LLM only when `LOCAL_AGENT_SIMULATOR_MODEL_CONFIG` is set in the process environment:

```swift
let modelConfigJson = ProcessInfo.processInfo.environment["LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON"]
let providers: [RustRuntimeProviderConfiguration] = modelConfigJson.map {
    [
        .localLLM(
            model: "local.gguf.simulator",
            modelConfigJson: $0,
            maxContextTokens: 2048
        )
    ]
} ?? []
```

Keep `providerId: "mock"` by default so the app boots without a model. Users switch to Local LLM from the UI.

- [ ] **Step 6: Add UI picker in ChatView toolbar**

Add a compact `Menu` in `ChatView.toolbar`:

```swift
Menu {
    ForEach(viewModel.state.provider.profiles, id: \.id) { profile in
        Button(profile.displayName) {
            Task { await viewModel.selectProvider(profile.id) }
        }
        .disabled(viewModel.state.phase.isRunning)
    }
} label: {
    Image(systemName: "cpu")
}
.accessibilityLabel("Provider")
```

Do not show model paths or C++ details in the UI.

- [ ] **Step 7: Run app tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State/AgentViewState.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Runtime/AgentRuntimeService.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/AgentViewModel.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation/Chat/ChatView.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Runtime/AgentRuntimeServiceTests.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Presentation/Chat/AgentViewModelTests.swift
git commit -m "Add local llm provider selection to app"
```

## Task 10: Simulator llama.cpp Manual Smoke And Report

**Files:**
- Create: `local-ios-agent/scripts/build-local-inference-simulator.sh`
- Create: `local-ios-agent/scripts/run-simulator-llamacpp-smoke.sh`
- Modify: `local-ios-agent/docs/model-evaluation/simulator-llamacpp-report.md`

- [ ] **Step 1: Add local build script**

Create `local-ios-agent/scripts/build-local-inference-simulator.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON:?set LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON}"
: "${SIMULATOR_UDID:?set SIMULATOR_UDID}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild -quiet \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test
```

- [ ] **Step 2: Add smoke runbook script**

Create `local-ios-agent/scripts/run-simulator-llamacpp-smoke.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LOCAL_AGENT_SIMULATOR_GGUF:?set LOCAL_AGENT_SIMULATOR_GGUF}"

CONFIG_JSON="$(python3 - <<PY
import json, os
print(json.dumps({
  "backend": "llama_cpp",
  "model_id": "local.gguf.simulator",
  "model_path": os.environ["LOCAL_AGENT_SIMULATOR_GGUF"],
  "chat_template": "gguf",
  "max_context_tokens": 2048,
  "generation": {
    "temperature": 0.2,
    "top_p": 0.9,
    "max_new_tokens": 128,
    "seed": 42
  },
  "llama_cpp": {
    "n_gpu_layers": 0,
    "n_threads": 4,
    "mmproj_path": ""
  }
}))
PY
)"

export LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON="$CONFIG_JSON"
"$ROOT/scripts/build-local-inference-simulator.sh"
```

- [ ] **Step 3: Record report template**

Create `local-ios-agent/docs/model-evaluation/simulator-llamacpp-report.md`:

```markdown
# Simulator llama.cpp Report

## Environment

- Git SHA:
- macOS:
- Xcode:
- Simulator runtime:
- llama.cpp revision:
- Model path:
- Model SHA256:
- Backend: llama_cpp

## Results

| Prompt | Success | Request to completed latency | Output chars | Error |
| --- | --- | ---: | ---: | --- |
| Say hello in Chinese. |  |  |  |  |
| Summarize what local inference means. |  |  |  |  |
| Continue this two-turn context. |  |  |  |  |

## Known Limits

- This is iOS Simulator app-process inference, not iPhone thermal or battery validation.
- The model artifact is not committed to git.
- MiniCPM acceptance depends on llama.cpp compatibility for the selected GGUF artifact.
```

- [ ] **Step 4: Run manual smoke**

```bash
LOCAL_AGENT_SIMULATOR_GGUF=/absolute/path/to/model.gguf \
SIMULATOR_UDID=$SIMULATOR_UDID \
local-ios-agent/scripts/run-simulator-llamacpp-smoke.sh
```

Expected: Xcode app test exits 0, and the manual app run can switch from Mock to Local LLM and complete one prompt.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/scripts/build-local-inference-simulator.sh \
  local-ios-agent/scripts/run-simulator-llamacpp-smoke.sh \
  local-ios-agent/docs/model-evaluation/simulator-llamacpp-report.md
git commit -m "Add simulator llama cpp smoke runbook"
```

## Final Verification

Run:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml
swift test --package-path local-ios-agent/toolkit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet \
  -project local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test
```

Run linked mock backend:

```bash
cargo test --manifest-path local-ios-agent/rust-core/Cargo.toml \
  --features link-mock-local-inference \
  --test local_llm_provider
```

Run real simulator llama.cpp smoke only when local model and llama.cpp artifacts are configured:

```bash
LOCAL_AGENT_SIMULATOR_GGUF=/absolute/path/to/model.gguf \
SIMULATOR_UDID=$SIMULATOR_UDID \
local-ios-agent/scripts/run-simulator-llamacpp-smoke.sh
```

Run clean-architecture guard checks:

```bash
rg -n "LlamaBridge|NativeLlamaEngineAdapter|llama|LocalAgentBackend" \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Presentation \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/State \
  local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Tools

rg -n "#include <vector>|#include <string>|#include <memory>|llama.h|mtmd.h|LocalAgentBackend" \
  local-ios-agent/inference/objc_bridge/LlamaBridge.h
```

Expected: both `rg` commands exit with code 1 and no matches.

## Definition Of Done

- Simulator App can boot with Mock when no model is configured.
- Simulator App can register `local_llm` when `LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON` is configured.
- Local LLM provider runs through Rust `ModelProvider`, not direct Swift-to-C++ calls.
- SwiftUI, ViewModels, reducers, and tools do not import `LlamaBridge`, llama.cpp, C ABI handles, or native backend adapter types.
- `LLMEngineProtocol` is the Swift business boundary for local model capabilities.
- `LlamaBridge.h` exposes only Objective-C/Foundation/UIKit types and blocks.
- `LlamaBridge.mm` is the only Swift-facing file allowed to translate `UIImage` into RGB bytes.
- llama.cpp is consumed through a produced XCFramework/static library, not by dragging upstream C++ source into the app target.
- C++ backend is split into C ABI, model config, engine interface, token stream, mock backend, and llama.cpp backend.
- C++ receives no session ID, run ID, tool call ID, Swift type, or Rust runtime type.
- Token deltas reach Swift through callback/closure/`AsyncThrowingStream` without waiting for the full completion.
- Optional image inference requires `mmproj_path` and keeps `mtmd_tokenize` inside `llama_cpp_api.cpp`.
- llama.cpp is replaceable by adding another `InferenceEngine`.
- MiniCPM is treated as a model artifact compatibility choice, not as a hardcoded backend.
- Model weights remain outside git.
- The report clearly states Simulator results are not iPhone thermal, battery, or final device performance.
