# On-Device MiniCPM Boundary

This document records both the temporary legacy Rust provider path and the
Phase 2 Swift-owned on-device product boundary. New product work follows the
Phase 2 boundary; the legacy path remains only until the Phase 4 host session
bridge reaches parity.

## Phase 2 Product Ownership (2026-07-15)

Swift owns model catalog trust, model directories, download/pause/resume,
verification, install/reconcile/delete, exact `LLMTargetRevision` selection,
capabilities, parameters, prepared sessions, RAM routing, and normalized LLM
events. Swift loads model weights only when that exact local target is prepared.

Rust owns the provider-neutral Agent state machine, context and tool policy,
durable run/preparation state, and—starting in Phase 4—opaque host commands and
event receipts. Rust does not own model paths, engine IDs, catalog manifests,
downloads, or native model handles. `host_slot_v2` is intentionally
non-runnable before the Phase 4 bridge.

C++ owns only validated local inference: engine/model/generation handles,
backend-specific template rendering/tokenization, token/usage/terminal facts,
and one cancel arbiter. It has no Agent, Provider Profile, download, storage,
Keychain, egress, or UI concepts.

## Legacy Compatibility Ownership

Rust owns:

- provider selection through the existing registry/runtime abstractions;
- `PromptFrame` to backend prompt JSON conversion;
- backend token JSON to `ModelProviderOutput` conversion;
- runtime cancellation tokens and error mapping;
- tools, memory, policy, sessions, and UI state.

C++ owns:

- model loading from backend-local model configuration JSON;
- model resource lifetime;
- token production for one stream handle;
- backend-local cancellation for that stream handle;
- backend and stream release.

C++ must not know about session IDs, run IDs, tools, memory stores, approval
policy, SwiftUI, or provider registry state.

## Legacy Compatibility C ABI

The following old backend/stream ABI is retained only for the Rust legacy
compatibility route. The Phase 2 Swift product path uses the versioned
engine/model/generation ABI in `inference/include/local_agent_inference.h`.

```c
LocalAgentStatus local_agent_backend_init(LocalAgentBackend **out_backend);
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
LocalAgentStatus local_agent_backend_start_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    LocalAgentBackendStream **out_stream
);
LocalAgentStatus local_agent_backend_read_stream(
    LocalAgentBackendStream *stream,
    local_agent_token_callback callback,
    void *user_data
);
LocalAgentStatus local_agent_backend_cancel(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release_stream(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release(LocalAgentBackend *backend);
```

Rust uses the split `start_chat` / `read_stream` path. `start_chat` must return
the opaque stream handle before token production enters a blocking loop. Rust can
then hold that handle while `read_stream` is active, call
`local_agent_backend_cancel(stream)` from cancellation watcher timing, and
release the stream exactly once. `stream_chat` remains a C-side convenience
wrapper for smoke tests and simple callers.

## Token Contract

The backend emits one JSON object per callback:

```json
{"type":"text_delta","text":"..."}
{"type":"completed","text":"..."}
```

Rust maps these into `ModelProviderOutput::TextDelta` and
`ModelProviderOutput::Completed`. Backend token JSON is deliberately provider
level data, not runtime state.

## Cancellation

Plan 11 cancellation is backend-scoped:

```text
Provider cancellation token
  -> CAbiLocalInferenceBackend starts a stream and holds its handle
  -> read_stream enters the backend loop
  -> Rust cancellation watcher observes cancellation
  -> local_agent_backend_cancel(stream)
  -> backend stream loop returns LOCAL_AGENT_STATUS_CANCELLED
  -> Rust maps to AgentError::Cancelled
  -> Rust releases stream handle exactly once
```

Application-level cancellation remains owned by Plan 10. When the active
provider is on-device, the Plan 10 cancellation path must signal the provider
cancellation token that reaches this backend adapter.

## Replacement Path

The current C++ backend is a deterministic mock used for ABI and lifecycle
coverage. A real llama.cpp/GGUF/Metal backend should replace only the
implementation behind `local_agent_inference.h`:

- keep the opaque backend and stream types;
- keep prompt input as JSON;
- keep token output as JSON callbacks;
- preserve `start_chat` as the point where a cancellable stream handle becomes
  available;
- preserve `read_stream` as the token production loop;
- preserve `cancel(stream)` as a stream-local primitive that can interrupt
  `read_stream`;
- preserve explicit release for streams and backend resources.

If replacing the mock requires Rust runtime, session, tool, or UI types inside
C++, the boundary has leaked and should be redesigned before continuing.
