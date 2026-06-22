# Simulator llama.cpp Model Contract

The simulator local inference path loads a GGUF model inside the iOS Simulator app process through the local inference C ABI.

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
    "max_new_tokens": 512,
    "seed": 42
  },
  "llama_cpp": {
    "n_gpu_layers": 0,
    "n_threads": 4,
    "mmproj_path": ""
  }
}
```

For interactive chat, set `generation.max_new_tokens` between 512 and 1024 so
the UI can exercise long streaming behavior. Smoke tests may use 128 to keep
test runtime short.

## Xcode Run Configuration

Command-line scripts export the simulator model configuration before invoking
`xcodebuild`, but Xcode's GUI Run action does not inherit shell environment
variables. For GUI runs, add this environment variable in the LocalAgentApp
scheme under `Run > Arguments > Environment Variables`:

```text
LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON
```

The value should be the model configuration JSON, including an absolute
`model_path` to the GGUF file.

GUI runs also require the llama.cpp framework to be linked and available to the
app target. If the backend is built as an XCFramework, add the generated
`llama.xcframework` to the LocalAgentApp target's frameworks and ensure the
simulator slice is available for the selected destination.

## Model Acceptance Gate

The selected model must pass all gates:

1. The file is GGUF.
2. llama.cpp can load it on macOS with `llama-cli`.
3. The iOS Simulator build can load it through `local_agent_backend_load_model`.
4. A single prompt produces at least one `text_delta` and one `completed` token event.
5. Cancellation releases the stream exactly once.

MiniCPM may be used only when its artifact satisfies these gates. If a MiniCPM artifact cannot be loaded by llama.cpp, record that result and use a smaller compatible GGUF for the architecture smoke while keeping the backend model-agnostic.
