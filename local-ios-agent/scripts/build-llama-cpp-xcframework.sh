#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$ROOT/third_party/llama.cpp}"

if [[ ! -f "$LLAMA_CPP_DIR/build-xcframework.sh" ]]; then
  echo "Missing llama.cpp checkout at $LLAMA_CPP_DIR" >&2
  echo "Clone ggml-org/llama.cpp there, pin the revision in docs/model-providers/simulator-llamacpp-contract.md, then rerun." >&2
  exit 2
fi

(
  cd "$LLAMA_CPP_DIR"
  ./build-xcframework.sh
)

test -d "$LLAMA_CPP_DIR/build-apple/llama.xcframework"
echo "$LLAMA_CPP_DIR/build-apple/llama.xcframework"
