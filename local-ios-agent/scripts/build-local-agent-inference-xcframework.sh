#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_COMMON_DIR="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)"
MAIN_REPOSITORY="$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd)"
PROJECTS_ROOT="$(dirname "$MAIN_REPOSITORY")"
LLAMA_CPP_ROOT="${LLAMA_CPP_ROOT:-$PROJECTS_ROOT/minicpmv-town/third_party/llama.cpp}"
RELEASE_ENGINES="$ROOT/inference/release-engines.json"
OUTPUT="${LOCAL_AGENT_INFERENCE_XCFRAMEWORK:-$ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework}"
BUILD_ROOT="${LOCAL_AGENT_INFERENCE_BUILD_ROOT:-/private/tmp/local-agent-inference-native}"
CXX="${CXX:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++}"
LIBTOOL="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool"
LIPO="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo"

if [[ ! -x "$CXX" || ! -x "$LIBTOOL" || ! -x "$LIPO" ]]; then
  echo "Xcode C++/libtool/lipo tools are required" >&2
  exit 1
fi
if [[ ! -f "$LLAMA_CPP_ROOT/include/llama.h" ]]; then
  echo "missing pinned llama.cpp source tree: $LLAMA_CPP_ROOT" >&2
  exit 1
fi

release_engine_count="$(/usr/bin/plutil -extract engine_ids raw -o - "$RELEASE_ENGINES")"
release_engine_id="$(/usr/bin/plutil -extract engine_ids.0 raw -o - "$RELEASE_ENGINES")"
if [[ "$release_engine_count" != "1" || "$release_engine_id" != "llama_cpp" ]]; then
  echo "unsupported release engine allowlist; Phase 2 currently ships exactly llama_cpp" >&2
  exit 1
fi

COMMON_SOURCES=(
  inference/c_api/local_agent_inference.cpp
  inference/core/json_value.cpp
  inference/core/model_config.cpp
  inference/core/generation_request.cpp
  inference/core/engine_registry.cpp
  inference/core/token_stream.cpp
  inference/backends/llama_cpp/llama_cpp_api.cpp
  inference/backends/llama_cpp/llama_cpp_engine.cpp
  inference/backends/llama_cpp/llama_cpp_prompt.cpp
)
VENDOR_ARCHIVES=(
  libllama.a
  libggml.a
  libggml-base.a
  libggml-cpu.a
  libggml-metal.a
  libggml-blas.a
)

prepare_headers() {
  local headers="$BUILD_ROOT/Headers"
  mkdir -p "$headers"
  cp "$ROOT/inference/include/local_agent_inference.h" "$headers/"
  cp "$ROOT/inference/include/module.modulemap" "$headers/"
}

thin_archive() {
  local source="$1"
  local output="$2"
  if "$LIPO" -info "$source" 2>&1 | grep -q "Architectures in the fat file"; then
    "$LIPO" "$source" -thin arm64 -output "$output"
  else
    cp "$source" "$output"
  fi
}

build_slice() {
  local name="$1"
  local sdk="$2"
  local target="$3"
  local vendor_build="$4"
  local slice="$BUILD_ROOT/$name"
  local objects="$slice/objects"
  local vendor="$slice/vendor"
  local sdk_path
  sdk_path="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun --sdk "$sdk" --show-sdk-path)"
  mkdir -p "$objects" "$vendor"

  local index=0
  for source in "${COMMON_SOURCES[@]}"; do
    "$CXX" -std=c++17 -O2 -fvisibility=hidden \
      -target "$target" -isysroot "$sdk_path" \
      -DLOCAL_AGENT_ENABLE_LLAMA_CPP \
      -I "$ROOT/inference/include" \
      -I "$ROOT/inference/core" \
      -I "$ROOT/inference/backends/llama_cpp" \
      -I "$LLAMA_CPP_ROOT/include" \
      -I "$LLAMA_CPP_ROOT/ggml/include" \
      -c "$ROOT/$source" -o "$objects/$index.o"
    index=$((index + 1))
  done

  local archive
  local found
  local thinned=()
  for archive in "${VENDOR_ARCHIVES[@]}"; do
    found="$(find "$LLAMA_CPP_ROOT/$vendor_build" -type f -name "$archive" -path '*/Release*/*' -print -quit)"
    if [[ -z "$found" ]]; then
      echo "missing static llama.cpp vendor archive for $name: $archive" >&2
      exit 1
    fi
    thin_archive "$found" "$vendor/$archive"
    thinned+=("$vendor/$archive")
  done

  "$LIBTOOL" -static -o "$slice/liblocal_agent_inference_native.a" \
    "$objects"/*.o "${thinned[@]}"
}

rm -rf "$BUILD_ROOT" "$OUTPUT"
mkdir -p "$BUILD_ROOT" "$(dirname "$OUTPUT")"
prepare_headers
build_slice macos-arm64 macosx arm64-apple-macos14.0 build-macos
build_slice ios-arm64-simulator iphonesimulator arm64-apple-ios17.0-simulator build-ios-sim
build_slice ios-arm64 iphoneos arm64-apple-ios17.0 build-ios-device

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/macos-arm64/liblocal_agent_inference_native.a" -headers "$BUILD_ROOT/Headers" \
  -library "$BUILD_ROOT/ios-arm64-simulator/liblocal_agent_inference_native.a" -headers "$BUILD_ROOT/Headers" \
  -library "$BUILD_ROOT/ios-arm64/liblocal_agent_inference_native.a" -headers "$BUILD_ROOT/Headers" \
  -output "$OUTPUT"

echo "built $OUTPUT"
