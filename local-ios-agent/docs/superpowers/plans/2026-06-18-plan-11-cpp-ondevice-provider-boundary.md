# Plan 11: C++ Inference Backend Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the on-device inference backend boundary for future llama.cpp / GGUF / Metal integration.

**Architecture:** Plan 11 owns inference backend mechanics only. C++ owns model loading, resource lifetime, token production, backend-local cancellation, and release. Rust adapts that backend into an `OnDeviceMiniCPMProvider` that conforms to the provider abstraction from Plan 10. Runtime sessions, tools, memory, policy, and UI never enter the C++ layer.

**Tech Stack:** C ABI, C++17 mock backend, Rust 2021, Plan 10 provider abstraction, cargo tests, clang smoke build, TDD.

---

## Current Code Audit

Expected after Plan 10:

- Rust has a provider profile/registry layer.
- Desktop MiniCPM proves non-mock provider replacement.
- Provider selection is a runtime operation.

Still missing:

- `inference` directory;
- C ABI header;
- mock C++ backend;
- Rust backend adapter;
- smoke test that links or calls the mock C ABI;
- cancellation semantics at the backend boundary.

## Ownership Boundary

Plan 11 owns:

- inference C ABI;
- C++ mock backend;
- Rust `LocalInferenceBackend` abstraction;
- C ABI-backed Rust adapter;
- `OnDeviceMiniCPMProvider`;
- backend lifecycle tests for load, stream, cancel, and release;
- documentation for future llama.cpp / Metal replacement.

Plan 11 does not own:

- provider registry design;
- Desktop MiniCPM HTTP provider;
- Swift bridge;
- SwiftUI;
- native iOS tools.

## Integration Points

- Plan 10 owns provider selection and provider-generation cancellation. Plan 11
  exposes backend `cancel`; Plan 10 is responsible for invoking that backend
  primitive from runtime cancellation.
- Plan 12 may expose an on-device provider choice, but the provider works
  through Plan 10, not directly through UI.
- The C ABI should remain narrow enough that real llama.cpp can replace the mock
  backend without touching Rust runtime state.

## Cancellation Scope

Plan 11 cancellation is backend-scoped smoke coverage:

```text
backend_cancel(stream_handle)
  -> interrupts backend stream loop
  -> returns cancelled status
  -> releases backend resources safely
```

It is not sufficient by itself for app-level cancellation. The runtime-to-provider
cancel signal is owned by Plan 10 and must call into this backend primitive when
the active provider is on-device.

## C ABI Contract

The C ABI must make stream ownership explicit. `stream_chat` returns an opaque
stream handle, and `cancel` takes that exact handle:

```c
typedef struct LocalAgentBackend LocalAgentBackend;
typedef struct LocalAgentBackendStream LocalAgentBackendStream;

typedef void (*local_agent_token_callback)(
    const char *token_json,
    void *user_data
);

LocalAgentStatus local_agent_backend_init(
    LocalAgentBackend **out_backend
);

LocalAgentStatus local_agent_backend_load_model(
    LocalAgentBackend *backend,
    const char *model_config_json
);

LocalAgentStatus local_agent_backend_stream_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    local_agent_token_callback callback,
    void *user_data,
    LocalAgentBackendStream **out_stream
);

LocalAgentStatus local_agent_backend_cancel(
    LocalAgentBackendStream *stream
);

LocalAgentStatus local_agent_backend_release_stream(
    LocalAgentBackendStream *stream
);

LocalAgentStatus local_agent_backend_release(
    LocalAgentBackend *backend
);
```

The Rust `CAbiLocalInferenceBackend` must hold the stream handle while tokens
are being produced, call `local_agent_backend_cancel(stream)` for backend-local
cancellation, and always release the stream handle exactly once.

## File Structure

Create:

```text
local-ios-agent/inference/include/local_agent_inference.h
local-ios-agent/inference/mock/local_agent_inference_mock.cpp
local-ios-agent/rust-core/src/core/ondevice_minicpm.rs
local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs
local-ios-agent/docs/model-providers/ondevice-minicpm-boundary.md
```

Modify:

```text
local-ios-agent/rust-core/src/core/mod.rs
```

## Task 1: Define the Inference C ABI

- [ ] Add `local_agent_backend_init`.
- [ ] Add `local_agent_backend_load_model`.
- [ ] Add `local_agent_backend_stream_chat` returning
  `LocalAgentBackendStream **out_stream`.
- [ ] Add `local_agent_backend_cancel(LocalAgentBackendStream *stream)`.
- [ ] Add `local_agent_backend_release_stream(LocalAgentBackendStream *stream)`.
- [ ] Add `local_agent_backend_release`.
- [ ] Keep all session/tool/UI concerns out of the header.

## Task 2: Add Mock C++ Backend

- [ ] Implement the C ABI in C++17.
- [ ] Track loaded/cancelled state.
- [ ] Emit deterministic token callbacks.
- [ ] Verify `local_agent_backend_cancel(stream)` interrupts a mock stream and
  returns a cancelled status.
- [ ] Compile the mock backend with `clang++` as a smoke check.

## Task 3: Add Rust Backend Adapter

- [ ] Add `LocalInferenceBackend`.
- [ ] Add `MockLocalInferenceBackend` for Rust-only tests.
- [ ] Add `CAbiLocalInferenceBackend` that calls the mock C ABI.
- [ ] Add tests proving Rust can load, stream, cancel, and release through the
  backend abstraction.
- [ ] Add one smoke test that exercises the C ABI-backed adapter rather than
  only the Rust mock backend.

## Task 4: Add On-Device Provider Adapter

- [ ] Add `OnDeviceMiniCPMProvider`.
- [ ] Convert `PromptFrame` into backend prompt JSON.
- [ ] Convert backend tokens into `ModelProviderOutput`.
- [ ] Surface cancellation and backend errors as `AgentError`.

## Verification

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 -I inference/include -c inference/mock/local_agent_inference_mock.cpp -o /tmp/local_agent_inference_mock.o
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test ondevice_minicpm_provider
cargo test
```

## Self-Review

- Plan 11 owns inference, not provider selection UI.
- C++ only sees prompt JSON and emits tokens/status.
- Backend cancel remains a primitive; Plan 10 owns runtime/provider cancellation
  closure.
- Rust runtime state stays outside the inference backend.
