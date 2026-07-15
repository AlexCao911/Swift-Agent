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

C++ code must not include Rust headers, Swift headers, session IDs, run IDs,
tool call IDs, provider registry types, catalog/download/storage code, API-key
handling, or network policy.

## Phase 2 Product Boundary (2026-07-15)

The shipping owner is the single package-contained
`toolkit/Artifacts/LocalAgentInferenceNative.xcframework`. Its static slices
contain this adapter and every enabled vendor runtime; the App and SwiftPM test
host must not link a second llama.cpp or LiteRT binary. Rust uses
`static:-bundle` only for its temporary legacy consumer and never compiles or
archives C++ objects.

Swift owns catalog trust, downloads, model directories, installation state,
disk policy, exact target selection, capability intersection, semantic
parameters, prepared sessions, tool-call decoding, and user-visible recovery.
C++ receives only validated engine/model configuration plus one normalized
generation request, owns model/generation handles, streams backend facts, and
performs backend cancellation. Only the selected installation is loaded into
RAM; switching away unloads RAM while leaving verified files on disk until an
explicit Swift deletion flow succeeds.

The release registry is non-empty and must exactly equal both
`inference/release-engines.json` and the engine IDs used by the signed official
catalog. The deterministic link gate verifies exactly one definition of every
C ABI export and no unresolved allowlisted vendor symbol in Simulator and
iPhoneOS App binaries.

## Replacement Rule

Replacing llama.cpp/LiteRT with Core ML, MLC, ExecuTorch, or another engine must only require a new `InferenceEngine` implementation and a new backend factory branch. C ABI, Rust runtime, and SwiftUI must remain unchanged.
