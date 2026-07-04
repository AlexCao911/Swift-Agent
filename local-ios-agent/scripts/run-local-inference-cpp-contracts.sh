#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${LOCAL_AGENT_CPP_TEST_BUILD_DIR:-/tmp/local-agent-inference-contracts}"
CC_BIN="${CC:-clang}"
CXX_BIN="${CXX:-clang++}"

mkdir -p "$BUILD_DIR"
cd "$ROOT"

CXXFLAGS=(
  -std=c++17
  -DLOCAL_AGENT_ENABLE_TEST_ENGINES
  -I inference/include
  -I inference/core
  -I inference/backends/mock
  -I inference/backends/llama_cpp
  -I inference/backends/litert
)

"$CC_BIN" -std=c11 -I inference/include \
  -c inference/tests/header_contract.c \
  -o "$BUILD_DIR/header_contract.o"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/token_stream_contract.cpp \
  inference/core/token_stream.cpp \
  -o "$BUILD_DIR/token_stream_contract"
"$BUILD_DIR/token_stream_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/model_config_contract.cpp \
  inference/core/model_config.cpp \
  -o "$BUILD_DIR/model_config_contract"
"$BUILD_DIR/model_config_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/llama_cpp_backend_contract.cpp \
  inference/core/model_config.cpp \
  inference/core/token_stream.cpp \
  inference/backends/llama_cpp/llama_cpp_api.cpp \
  inference/backends/llama_cpp/llama_cpp_engine.cpp \
  inference/backends/llama_cpp/llama_cpp_prompt.cpp \
  -o "$BUILD_DIR/llama_cpp_backend_contract"
if "$BUILD_DIR/llama_cpp_backend_contract"; then
  :
else
  status=$?
  if [[ "$status" != "77" ]]; then
    exit "$status"
  fi
fi

echo "local inference C++ contracts passed"
