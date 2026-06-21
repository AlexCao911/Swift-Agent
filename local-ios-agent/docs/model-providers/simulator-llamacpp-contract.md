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
