# Swift Agent Core Boundary

Swift code must treat local inference as an AgentRuntime capability, not as a native engine library.

## Single Entry Point

All LLM calls in the app must enter through:

```text
AgentViewModel
  -> AgentRuntimeServicing
  -> RustRuntimeClient
  -> Rust AgentRuntime
  -> LocalLLMProvider
```

## Forbidden App Dependencies

The app target's Presentation, State, Runtime service, and Tools layers must not import or mention:

- `LocalAgentBackend`
- `LlamaBridge`
- `NativeLlamaEngineAdapter`
- `LLMEngineProtocol`
- `llama`
- `mtmd`
- C++ headers
- C ABI headers

## Provider Rule

Provider selection is app-visible, but inference execution is not. Selecting `local_llm` only changes Rust provider registry state; it must not create a Swift-native model object.

## Physical Link Rule

The app may link the Rust/C ABI native inference artifact required by `RustRuntimeClient`. Upstream llama.cpp source files stay outside the Xcode app target.

## Streaming Rule

Native token callbacks must be converted to Rust runtime events and then to Swift DTOs immediately. Collecting a full completion before updating Swift state violates this contract.
