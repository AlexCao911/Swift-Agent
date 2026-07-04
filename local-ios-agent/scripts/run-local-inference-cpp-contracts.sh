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

RELEASE_CXXFLAGS=(
  -std=c++17
  -I inference/include
  -I inference/core
  -I inference/backends/mock
  -I inference/backends/llama_cpp
  -I inference/backends/litert
)

LITERT_VENDOR_CXXFLAGS=()
if [[ -n "${LOCAL_AGENT_LITERT_LM_CXXFLAGS:-}" ]]; then
  read -r -a LITERT_VENDOR_CXXFLAGS <<< "$LOCAL_AGENT_LITERT_LM_CXXFLAGS"
fi

LITERT_VENDOR_LDFLAGS=()
if [[ -n "${LOCAL_AGENT_LITERT_LM_LDFLAGS:-}" ]]; then
  read -r -a LITERT_VENDOR_LDFLAGS <<< "$LOCAL_AGENT_LITERT_LM_LDFLAGS"
fi

COMMON_SOURCES=(
  inference/c_api/local_agent_inference.cpp
  inference/core/json_value.cpp
  inference/core/model_config.cpp
  inference/core/generation_request.cpp
  inference/core/engine_registry.cpp
  inference/core/token_stream.cpp
  inference/backends/mock/mock_inference_engine.cpp
  inference/backends/llama_cpp/llama_cpp_api.cpp
  inference/backends/llama_cpp/llama_cpp_engine.cpp
  inference/backends/llama_cpp/llama_cpp_prompt.cpp
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
  inference/core/json_value.cpp \
  inference/core/model_config.cpp \
  -o "$BUILD_DIR/model_config_contract"
"$BUILD_DIR/model_config_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/json_value_contract.cpp \
  inference/core/json_value.cpp \
  -o "$BUILD_DIR/json_value_contract"
"$BUILD_DIR/json_value_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/generation_request_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/generation_request.cpp \
  -o "$BUILD_DIR/generation_request_contract"
"$BUILD_DIR/generation_request_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/engine_registry_contract.cpp \
  inference/core/engine_registry.cpp \
  inference/core/token_stream.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o "$BUILD_DIR/engine_registry_contract"
"$BUILD_DIR/engine_registry_contract"

"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" -DLOCAL_AGENT_ENABLE_LLAMA_CPP \
  -c inference/core/engine_registry.cpp \
  -o "$BUILD_DIR/engine_registry_llama.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  -c inference/backends/llama_cpp/llama_cpp_engine.cpp \
  -o "$BUILD_DIR/llama_cpp_engine.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  -c inference/backends/llama_cpp/llama_cpp_api.cpp \
  -o "$BUILD_DIR/llama_cpp_api.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  -c inference/backends/llama_cpp/llama_cpp_prompt.cpp \
  -o "$BUILD_DIR/llama_cpp_prompt.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  -c inference/core/generation_request.cpp \
  -o "$BUILD_DIR/generation_request_for_llama.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  -c inference/core/token_stream.cpp \
  -o "$BUILD_DIR/token_stream_for_llama.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  -c inference/core/json_value.cpp \
  -o "$BUILD_DIR/json_value_for_llama.o"
"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  inference/tests/engine_registry_llama_contract.cpp \
  "$BUILD_DIR/engine_registry_llama.o" \
  "$BUILD_DIR/llama_cpp_engine.o" \
  "$BUILD_DIR/llama_cpp_api.o" \
  "$BUILD_DIR/llama_cpp_prompt.o" \
  "$BUILD_DIR/generation_request_for_llama.o" \
  "$BUILD_DIR/token_stream_for_llama.o" \
  "$BUILD_DIR/json_value_for_llama.o" \
  -o "$BUILD_DIR/engine_registry_llama_contract"
"$BUILD_DIR/engine_registry_llama_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" -DLOCAL_AGENT_ENABLE_LITERT \
  inference/tests/engine_registry_contract.cpp \
  inference/core/engine_registry.cpp \
  inference/core/token_stream.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o "$BUILD_DIR/engine_registry_litert_contract"
"$BUILD_DIR/engine_registry_litert_contract" --expect-litert-hidden

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/litert_active_generation_contract.cpp \
  inference/backends/litert/litert_active_generation.cpp \
  -o "$BUILD_DIR/litert_active_generation_contract"
"$BUILD_DIR/litert_active_generation_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/litert_quiesce_wait_contract.cpp \
  -o "$BUILD_DIR/litert_quiesce_wait_contract"
"$BUILD_DIR/litert_quiesce_wait_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/litert_backend_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/generation_request.cpp \
  inference/core/token_stream.cpp \
  inference/backends/litert/litert_api.cpp \
  inference/backends/litert/litert_engine.cpp \
  -o "$BUILD_DIR/litert_backend_contract"
"$BUILD_DIR/litert_backend_contract"

if [[ -n "${LOCAL_AGENT_LITERT_LM_INCLUDE_DIR:-}" ]]; then
  "$CXX_BIN" "${CXXFLAGS[@]}" \
    -DLOCAL_AGENT_ENABLE_LITERT \
    -DLOCAL_AGENT_ENABLE_LITERT_VENDOR \
    -I "$LOCAL_AGENT_LITERT_LM_INCLUDE_DIR" \
    "${LITERT_VENDOR_CXXFLAGS[@]}" \
    inference/tests/engine_registry_contract.cpp \
    inference/core/engine_registry.cpp \
    inference/core/token_stream.cpp \
    inference/backends/mock/mock_inference_engine.cpp \
    inference/backends/litert/litert_active_generation.cpp \
    inference/backends/litert/litert_engine.cpp \
    inference/backends/litert/litert_lm_api.cpp \
    "${LITERT_VENDOR_LDFLAGS[@]}" \
    -o "$BUILD_DIR/engine_registry_litert_vendor_contract"
  "$BUILD_DIR/engine_registry_litert_vendor_contract" --expect-litert-visible

  if [[ -n "${LOCAL_AGENT_LITERT_LM_MODEL_PATH:-}" ]]; then
    "$CXX_BIN" "${CXXFLAGS[@]}" \
      -DLOCAL_AGENT_ENABLE_LITERT \
      -DLOCAL_AGENT_ENABLE_LITERT_VENDOR \
      -I "$LOCAL_AGENT_LITERT_LM_INCLUDE_DIR" \
      "${LITERT_VENDOR_CXXFLAGS[@]}" \
      inference/tests/litert_lm_vendor_smoke.cpp \
      inference/c_api/local_agent_inference.cpp \
      inference/core/json_value.cpp \
      inference/core/model_config.cpp \
      inference/core/generation_request.cpp \
      inference/core/engine_registry.cpp \
      inference/core/token_stream.cpp \
      inference/backends/litert/litert_active_generation.cpp \
      inference/backends/litert/litert_engine.cpp \
      inference/backends/litert/litert_lm_api.cpp \
      "${LITERT_VENDOR_LDFLAGS[@]}" \
      -o "$BUILD_DIR/litert_lm_vendor_smoke"
    "$BUILD_DIR/litert_lm_vendor_smoke"
  else
    echo "skipping LiteRT-LM model smoke; set LOCAL_AGENT_LITERT_LM_MODEL_PATH to enable it"
  fi
else
  echo "skipping LiteRT-LM vendor contract; set LOCAL_AGENT_LITERT_LM_INCLUDE_DIR and LOCAL_AGENT_LITERT_LM_LDFLAGS to enable it"
fi

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/mock_backend_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/model_config.cpp \
  inference/core/generation_request.cpp \
  inference/core/token_stream.cpp \
  inference/backends/mock/mock_inference_engine.cpp \
  -o "$BUILD_DIR/mock_backend_contract"
"$BUILD_DIR/mock_backend_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/c_api_v2_contract.cpp \
  "${COMMON_SOURCES[@]}" \
  -o "$BUILD_DIR/c_api_v2_contract"
"$BUILD_DIR/c_api_v2_contract"

"$CXX_BIN" "${CXXFLAGS[@]}" \
  inference/tests/llama_cpp_backend_contract.cpp \
  inference/core/json_value.cpp \
  inference/core/model_config.cpp \
  inference/core/generation_request.cpp \
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

"$CXX_BIN" "${RELEASE_CXXFLAGS[@]}" \
  inference/tests/c_api_release_registry_contract.cpp \
  "${COMMON_SOURCES[@]}" \
  -o "$BUILD_DIR/c_api_release_registry_contract"
"$BUILD_DIR/c_api_release_registry_contract"

echo "local inference C++ contracts passed"
