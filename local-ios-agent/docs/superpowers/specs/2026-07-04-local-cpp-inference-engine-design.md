# Local C++ Inference Engine Design

Date: 2026-07-04

## Design Goal

Define the C++ local inference layer as a thin, stable, replaceable engine boundary for the app.

The design goal is:

```text
Swift App
  chooses a compiled local engine and provides model files/config

C++ Local Inference
  loads local model files and streams generation

Rust Agent Kernel
  remains unaware of local engine details
```

This document only designs the C++ local inference layer. Model download, model selection UI, cloud inference, agent composition, and native tools are intentionally out of scope for this phase.

## Current Context

The project already has a first local inference foundation:

```text
local-ios-agent/inference/
├── include/local_agent_inference.h
├── c_api/local_agent_inference.cpp
├── core/
│   ├── inference_engine.h
│   ├── model_config.h
│   └── token_stream.h
├── backends/
│   ├── mock/
│   └── llama_cpp/
└── tests/
```

The current v1 ABI exposes:

```text
local_agent_backend_init
local_agent_backend_load_model
local_agent_backend_start_chat
local_agent_backend_start_chat_with_image
local_agent_backend_read_stream
local_agent_backend_cancel
local_agent_backend_release_stream
local_agent_backend_release
```

This is good enough for early mock/llama.cpp integration, but the long-term local engine should explicitly separate:

```text
Engine
LoadedModel
GenerationSession
```

## Platform Constraint

iOS apps should not download and execute new native code after review. Local inference engines must be compiled, linked, and signed with the app.

Therefore:

```text
Compiled into the app
  llama.cpp adapter/runtime
  LiteRT adapter/runtime
  mock/test engine for debug and test builds only
  future Core ML / MLX / ExecuTorch adapters if used

Downloadable after install
  model weights
  tokenizer files
  mmproj files
  chat templates
  model manifests
```

The C++ layer must assume the engine binary is already present. It receives local file paths and config from the host app; it does not download engines or models.

Apple references:

```text
https://developer.apple.com/app-store/review/guidelines/#software-requirements
https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/On_Demand_Resources_Guide/
```

## Ownership Boundary

### C++ Owns

```text
engine registry for compiled local engines
engine capability reporting
model config parsing and validation
model load / unload
generation start
token stream read
generation cancel
generation release
native engine error mapping
usage metadata where available
```

### C++ Does Not Own

```text
model download
model catalog UI
model persistence policy
active model selection
cloud provider config
API keys
cloud HTTP inference
agent profiles
conversation history
tool calls
memory
Swift UI state
Rust domain objects
```

The host app gives C++ a complete local model load config. C++ validates and executes it.

## Target File Structure

```text
local-ios-agent/inference/
├── include/
│   └── local_agent_inference.h
├── c_api/
│   └── local_agent_inference.cpp
├── core/
│   ├── engine_registry.h/.cpp
│   ├── inference_engine.h
│   ├── loaded_model.h
│   ├── generation_session.h
│   ├── model_config.h/.cpp
│   ├── engine_capabilities.h
│   ├── local_agent_error.h
│   └── token_stream.h/.cpp
├── backends/
│   ├── mock/
│   ├── llama_cpp/
│   └── litert/
└── tests/
```

`mock/` is a test adapter. It should be compiled only for tests, debug builds, or internal smoke tooling. It must not appear as a user-selectable release engine.

`litert/` can remain a placeholder adapter until the dependency is selected and linked, but it is the intended second production local engine after llama.cpp.

## Engine Registry

C++ should expose a registry of engines compiled into the app:

```text
llama_cpp
litert
future: coreml, mlx, executorch
```

Test/debug registries may also expose:

```text
mock
```

The registry is not a plugin loader. It does not load runtime-downloaded dylibs or frameworks.

Internal shape:

```cpp
class EngineRegistry {
public:
    std::vector<EngineDescriptor> list() const;
    std::unique_ptr<InferenceEngine> create(const std::string &engine_id) const;
};
```

Descriptor:

```cpp
struct EngineDescriptor {
    std::string engine_id;
    std::string display_name;
    std::vector<std::string> supported_model_formats;
    bool supports_vision;
    bool supports_streaming;
    bool supports_cancellation;
    bool supports_token_usage;
};
```

Swift can call a C ABI wrapper to list descriptors and decide which compiled engine can open a downloaded model.

## Model Load Config

C++ receives a config assembled by the host app:

```json
{
  "engine": "llama_cpp",
  "model_id": "minicpm-v-4.6-q4",
  "model_format": "gguf",
  "model_path": ".../model.gguf",
  "mmproj_path": ".../mmproj.gguf",
  "chat_template": "gguf",
  "context_tokens": 8192,
  "runtime": {
    "n_threads": 4,
    "n_gpu_layers": 99
  }
}
```

C++ validates:

```text
engine exists in registry
model_path is present
model format is supported by engine
required multimodal files exist when vision is enabled
context_tokens is within engine/model capability
runtime options are valid for engine
```

C++ does not validate:

```text
download source
checksum trust
whether user owns this model
which model is active in the app
cloud provider credentials
```

Those are host app responsibilities.

## Generation Request

Generation config should be separated from model load config:

```json
{
  "messages": [
    {
      "role": "system",
      "content": "..."
    },
    {
      "role": "user",
      "content": "..."
    }
  ],
  "images": [
    {
      "format": "rgb",
      "width": 1024,
      "height": 768
    }
  ],
  "sampling": {
    "temperature": 0.2,
    "top_p": 0.9,
    "top_k": 40,
    "min_p": 0.05,
    "repeat_penalty": 1.1,
    "seed": 42,
    "max_new_tokens": 512,
    "stop_sequences": []
  }
}
```

Model load config changes require a model reload. Generation config can change per request.

### Multimodal Input Boundary

Generation JSON describes image metadata, but binary image bytes must cross the C ABI through explicit buffers or file references.

Supported v2 forms:

```text
inline buffer
  Swift passes pointer + byte_count + width + height + pixel_format for the lifetime of local_agent_generation_start.
  C++ copies any bytes it needs before the function returns.

file reference
  Swift passes a sandbox-local file path plus declared media type.
  C++ reads the file during generation start and owns any decoded buffers.
```

The first v2 implementation should keep parity with v1 and support an RGB buffer:

```c
typedef struct LocalAgentImageInput {
    const uint8_t *bytes;
    uint64_t byte_count;
    uint32_t width;
    uint32_t height;
    const char *pixel_format; /* "rgb8" first */
} LocalAgentImageInput;
```

Representative v2 generation start signature:

```c
LocalAgentStatus local_agent_generation_start(
    LocalAgentModelHandle *model,
    const char *generation_request_json,
    const LocalAgentImageInput *images,
    uint64_t image_count,
    LocalAgentGenerationHandle **out_generation
);
```

For buffer inputs:

```text
caller owns the input buffer
buffer must remain valid until local_agent_generation_start returns
C++ must not retain the caller pointer after return
C++ must copy bytes if generation needs them later
```

For file inputs:

```text
caller owns the file
path must remain valid until local_agent_generation_start returns
C++ must open/read/copy what it needs before returning or report an error
```

Model config still owns model and mmproj paths. Generation request owns per-call images.

## Internal C++ Interfaces

### InferenceEngine

```cpp
class InferenceEngine {
public:
    virtual ~InferenceEngine() = default;
    virtual EngineCapabilities capabilities() const = 0;
    virtual std::unique_ptr<LoadedModel> load_model(const ModelLoadConfig &) = 0;
};
```

### LoadedModel

```cpp
class LoadedModel {
public:
    virtual ~LoadedModel() = default;
    virtual ModelRuntimeInfo runtime_info() const = 0;
    virtual std::unique_ptr<GenerationSession> start_generation(
        const PromptInput &,
        const GenerationConfig &
    ) = 0;
};
```

### GenerationSession

```cpp
class GenerationSession {
public:
    virtual ~GenerationSession() = default;
    virtual void read(const TokenEmit &) = 0;
    virtual void cancel() = 0;
    virtual UsageReport usage() const = 0;
};
```

Each `GenerationSession` owns request-scoped generation state:

```text
prompt input
image input
sampler
temporary buffers
cancellation state
native generation context
```

Shared `LoadedModel` state should not store active request state.

## C ABI v2

The long-term ABI should expose opaque handles:

```text
LocalAgentEngineHandle
LocalAgentModelHandle
LocalAgentGenerationHandle
```

Functions:

```text
local_agent_engine_create
local_agent_engine_release
local_agent_engine_list
local_agent_engine_capabilities

local_agent_model_load
local_agent_model_unload

local_agent_generation_start
local_agent_generation_read
local_agent_generation_cancel
local_agent_generation_release

local_agent_last_error
```

The v1 ABI can remain during migration. The v2 ABI should be additive so existing tests and app paths keep working while Swift adopts the new handle model.

### C ABI Memory Ownership

v2 must define ownership at every pointer boundary.

Rules:

```text
Opaque handles
  C++ allocates handles returned by create/load/start.
  Caller releases them exactly once with the matching release function.
  Release functions must tolerate null handles.
  Passing a dangling already-released handle is invalid; Swift wrappers must guard against double release.

Input strings
  Caller owns const char * inputs.
  Inputs must remain valid only for the duration of the C function call.
  C++ copies any string it needs after the call returns.

Output strings / JSON
  C++ allocates returned char * buffers.
  Caller must release them with local_agent_string_free.
  Returned strings are UTF-8 and null-terminated.

Callback token JSON
  const char * passed to callback is owned by C++.
  It is valid only during the callback invocation.
  Callback must copy if it needs to retain the data.
  Callback must not free the pointer.

Output arrays
  Prefer JSON strings for engine lists/capabilities in v2.
  If a future array API is added, it must include explicit count and free function.
```

Required helper:

```c
void local_agent_string_free(char *value);
```

Representative v2 signatures:

```c
LocalAgentStatus local_agent_engine_list(char **out_json);
LocalAgentStatus local_agent_engine_capabilities(
    LocalAgentEngineHandle *engine,
    char **out_json
);
LocalAgentStatus local_agent_last_error(
    LocalAgentEngineHandle *engine,
    char **out_json
);
```

Every API that returns JSON must either:

```text
return it via char **out_json and require local_agent_string_free
or emit it through a callback with callback-lifetime ownership
```

It must not return borrowed pointers to internal C++ strings.

## Token Events

C++ should emit structured token events as JSON through the C ABI:

```json
{
  "type": "text_delta",
  "text": "hello"
}
```

Other event types:

```text
text_delta
reasoning_delta
structured_delta
usage
completed
error
```

The first implementation can support `text_delta`, `usage`, `completed`, and `error`.

C++ must not parse or normalize tool calls as an agent concept. If a local model emits structured text that may contain a tool call, C++ can forward it as `structured_delta` or plain text. Tool-call parsing and normalization belong to the Swift host inference layer or the Rust execution layer.

## Error Mapping

C++ maps native engine errors into stable local inference errors:

```text
invalid_argument
engine_unavailable
unsupported_model_format
model_file_missing
model_load_failed
context_too_large
vision_not_supported
generation_cancelled
generation_failed
stream_interrupted
usage_unavailable
internal_error
```

`local_agent_last_error` should return a structured JSON object:

```json
{
  "code": "model_load_failed",
  "message": "failed to load GGUF model",
  "engine": "llama_cpp",
  "recoverable": false
}
```

Vendor-specific details can be included in debug builds or redacted metadata, but the public error code must remain stable.

## Engine Adapter Rules

Each adapter must translate between the common C++ interfaces and the vendor engine.

### llama.cpp Adapter

Responsibilities:

```text
parse llama-specific runtime options
load GGUF model
load mmproj when required
format chat prompt
stream tokens
cancel generation
release llama resources
map llama errors
```

### LiteRT Adapter

Responsibilities:

```text
parse LiteRT-specific runtime options
load supported model package
run generation API
stream or chunk outputs if supported
cancel generation when API supports it
map LiteRT errors
```

If LiteRT does not expose the same streaming semantics as llama.cpp, the adapter still emits the common token event stream. It can buffer internally.

### Mock Adapter

The mock adapter is mandatory for deterministic tests, C ABI smoke tests, and early Swift bridge verification. It is not a product engine.

Release builds should exclude mock from the public engine registry. If keeping the mock source in the repository is useful, guard it behind a test/debug build flag. Once llama.cpp and LiteRT both have stable smoke coverage, app-facing tests should stop relying on mock for product behavior and use mock only for low-level deterministic contracts.

## Vendor Policy

Third-party inference engines should be integrated in this order:

```text
1. Official release or pinned source dependency
2. Git submodule pinned commit
3. Maintained fork only when upstream patches are required
```

Do not fork every engine by default. Each engine integration should have:

```text
pinned version
build script
license note
adapter contract tests
smoke test
known capability record
```

## Build and Packaging Policy

Local engines are build-time dependencies. They are not runtime plugins.

Recommended packaging:

```text
local-ios-agent/inference/
  owns common C ABI, core abstractions, and adapter code

third_party/
  owns pinned vendor source or submodules when needed

scripts/
  owns reproducible engine build scripts

Xcode project / Swift package integration
  links compiled static libraries or xcframeworks into the app
```

Each engine should have a build feature or product variant:

```text
mock_test
llama_cpp
llama_cpp_mtmd
litert
```

Release builds may choose which production engines to include to control binary size. The C++ engine registry must report only engines compiled into the current app binary, and release registries must not report `mock_test`.

Engine update workflow:

```text
pin new vendor version
update adapter only if vendor API changed
run C++ contract tests
run engine smoke test
update capability record
ship new app build
```

No app update means no new native engine code. Users can still download new compatible model weights for engines already shipped in the app.

## License and Size Gate

Before enabling an engine in a release build, record:

```text
vendor name and version
license
linked binary size impact
supported architectures
minimum OS/runtime requirement
hardware acceleration requirement
known unsupported model formats
```

This metadata is not part of the C ABI, but it should be available to build/release tooling and to the Swift host when presenting engine availability.

## Swift Boundary

Swift calls C++ through a stable local inference client.

Swift provides:

```text
engine_id
local model file paths
model metadata
generation request
image bytes when needed
cancel requests
```

C++ returns:

```text
engine descriptors
model runtime info
token events
usage
stable errors
```

Swift still owns:

```text
model download
model library
active model selection
cloud provider config
agent builder
chat UI
native tools
```

This document does not design those Swift modules in detail.

## Rust Boundary

Rust must not call C++ directly as a product-level dependency. Rust should continue to treat model inference as an abstract host capability.

C++ must not include Rust headers or Rust domain identifiers.

Current reality:

```text
rust-core/src/core/local_llm.rs still contains CAbiLocalInferenceBackend and LocalLLMProvider.
That path is a legacy/compatibility adapter for the current migration phase.
```

This design does not require deleting that adapter. The intended end state is:

```text
Swift HostInferenceRuntime owns the C++ local inference client.
Rust execution calls an abstract host LLM port.
Rust no longer owns product-level local model loading or C++ engine selection.
```

Until the host inference port exists, the Rust C ABI adapter may remain for tests and compatibility.

## Migration Strategy

### Phase 1: Document and Harden v1

```text
keep current v1 ABI
document v1 callback lifetime as callback-only borrowed token_json
add explicit engine descriptor for current backend
add stricter model_config validation
expand C++ contract tests
```

### Phase 2: Add Engine Registry

```text
add EngineRegistry
register mock in test/debug registry
register llama_cpp in production registry
add capabilities endpoint
keep v1 load/start API working through registry
```

### Phase 3: Add v2 Handles

```text
add EngineHandle
add ModelHandle
add GenerationHandle
split model load from generation start
add local_agent_string_free
define callback and returned JSON ownership
define image buffer/file input ownership
add last_error JSON
```

### Phase 4: Add LiteRT Adapter

```text
pin LiteRT dependency
add litert adapter
add model format compatibility
add tests and smoke coverage
enable litert as the second production engine
```

### Phase 5: Swift Adoption

Swift can then adopt v2 through a `LocalInferenceEngineClient`. That later Swift design is separate.

## Acceptance Checklist

- C++ layer is local inference only.
- C++ does not download engines or model weights.
- Users can only select engines compiled into the app.
- Release builds do not expose mock as a selectable engine.
- Model weights remain downloadable host app data.
- v1 C ABI remains compatible during migration.
- v2 ABI separates engine, loaded model, and generation session.
- v2 ABI defines ownership for every string, callback pointer, buffer, and handle.
- v2 ABI includes `local_agent_string_free` for returned JSON/string buffers.
- Multimodal generation defines whether image input crosses as buffer or file reference.
- Engine adapters do not leak vendor headers through the public C ABI.
- llama.cpp and LiteRT can coexist behind the same internal `InferenceEngine` interface.
- llama.cpp and LiteRT are the first two production local engines.
- Adding a new local engine requires an adapter and registry entry, not Rust changes.
- Swift can list compiled engines and call local generation without knowing vendor APIs.
- Rust remains unaware of C++ engine details.
- Existing Rust C ABI local LLM code is treated as legacy/compatibility until Swift HostInferenceRuntime replaces it.

## Test Boundary

C/C++ contract tests:

```text
public header compiles as C and C++
engine registry lists compiled engines
capabilities JSON is stable
returned JSON is released through local_agent_string_free
callback token_json is copied before callback returns in Swift tests
release functions tolerate null and double-release is rejected or guarded by wrapper tests
model config validation rejects invalid engine
model config validation rejects missing required paths
image buffer generation copies input before start returns
mock backend streams deterministic events
generation cancel stops stream
generation release is idempotent
last_error returns structured JSON
v1 compatibility path still works
v2 handle lifecycle works
```

Adapter tests:

```text
llama.cpp prompt formatting
llama.cpp model load smoke
llama.cpp image/mmproj validation
LiteRT capability reporting
LiteRT generation smoke when dependency is available
```

Integration smoke:

```text
debug/test Swift local inference client can list mock engine
debug/test Swift local inference client can load mock model
debug/test Swift local inference client can stream mock generation
debug/test Swift local inference client can cancel generation
release Swift local inference client registry does not expose mock
release Swift local inference client can list compiled production engines
```

## Non-Goals

This phase does not design or implement:

```text
Swift Model Center
model download UI
cloud provider API key flow
cloud inference HTTP client
agent composition
native iOS tools
chat UI
Rust inference ownership changes
runtime-downloaded native engine binaries
```
