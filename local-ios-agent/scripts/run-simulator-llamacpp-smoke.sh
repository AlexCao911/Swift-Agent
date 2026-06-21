#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LOCAL_AGENT_SIMULATOR_GGUF:?set LOCAL_AGENT_SIMULATOR_GGUF}"

CONFIG_JSON="$(python3 - <<PY
import json
import os

print(json.dumps({
    "backend": "llama_cpp",
    "model_id": "local.gguf.simulator",
    "model_path": os.environ["LOCAL_AGENT_SIMULATOR_GGUF"],
    "chat_template": "gguf",
    "max_context_tokens": 2048,
    "generation": {
        "temperature": 0.2,
        "top_p": 0.9,
        "max_new_tokens": 128,
        "seed": 42,
    },
    "llama_cpp": {
        "n_gpu_layers": 0,
        "n_threads": 4,
        "mmproj_path": "",
    },
}))
PY
)"

export LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON="$CONFIG_JSON"
"$ROOT/scripts/build-local-inference-simulator.sh"
