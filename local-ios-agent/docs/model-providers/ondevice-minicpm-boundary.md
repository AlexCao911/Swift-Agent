# On-Device MiniCPM Boundary

The on-device MiniCPM path is the phone runtime provider boundary for future
llama.cpp, GGUF, and Metal integration. It sits behind the Plan 10
`ModelProvider` contract and keeps runtime state out of the native inference
backend.

## Ownership

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

## C ABI

The ABI is intentionally narrow:

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
LocalAgentStatus local_agent_backend_cancel(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release_stream(LocalAgentBackendStream *stream);
LocalAgentStatus local_agent_backend_release(LocalAgentBackend *backend);
```

`stream_chat` must make stream ownership explicit by writing `out_stream` before
emitting callbacks. Rust can then hold the same opaque stream handle while token
callbacks are in flight, call `local_agent_backend_cancel(stream)` when provider
cancellation is observed, and release the stream exactly once.

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
  -> CAbiLocalInferenceBackend callback observes cancellation
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
- preserve `cancel(stream)` as a stream-local primitive;
- preserve explicit release for streams and backend resources.

If replacing the mock requires Rust runtime, session, tool, or UI types inside
C++, the boundary has leaked and should be redesigned before continuing.
