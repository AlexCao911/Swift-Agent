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
