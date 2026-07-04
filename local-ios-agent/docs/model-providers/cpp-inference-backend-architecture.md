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

backends/litert/*
  LiteRT engine adapter. Non-vendor builds keep this hidden from the public
  registry; vendor builds compile `litert_lm_api.cpp` and use LiteRT-LM
  Engine/Conversation APIs for real local LLM generation. Active generation
  teardown must wait for in-flight cancellation callbacks before releasing a
  LiteRT-LM Conversation; quiesce waiting is bounded and reports failure if the
  vendor runtime cannot settle.
```

## Forbidden Dependencies

C++ code must not include Rust headers, Swift headers, session IDs, run IDs, tool call IDs, or provider registry types.

## Replacement Rule

Replacing llama.cpp/LiteRT with Core ML, MLC, ExecuTorch, or another engine must only require a new `InferenceEngine` implementation and a new backend factory branch. C ABI, Rust runtime, and SwiftUI must remain unchanged.
