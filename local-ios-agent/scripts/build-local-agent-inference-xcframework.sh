#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_ROOT="$ROOT/ThirdParty/OpenMinisNative"
LOCK_FILE="$NATIVE_ROOT/native-sources.lock"
SOURCE_ROOT="$NATIVE_ROOT/.build/sources"
ARCHIVE_ROOT="$NATIVE_ROOT/.build/downloads"
RELEASE_ENGINES="$ROOT/inference/release-engines.json"
OUTPUT="${LOCAL_AGENT_INFERENCE_XCFRAMEWORK:-$ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework}"
BUILD_ROOT="${LOCAL_AGENT_INFERENCE_BUILD_ROOT:-/private/tmp/local-agent-inference-native}"
C_COMPILER="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
CXX_COMPILER="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
LIBTOOL="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/libtool"
LIPO="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo"

# shellcheck source=./native/common.sh
source "$ROOT/scripts/native/common.sh"

llama_record="$(native_source_record llama-cpp "$LOCK_FILE")"
IFS='|' read -r _ LLAMA_CPP_COMMIT LLAMA_CPP_URL LLAMA_CPP_DIGEST <<< "$llama_record"
if [[ ! "$LLAMA_CPP_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "locked llama.cpp revision must be a 40-character commit" >&2
  exit 1
fi

prepare_llama_cpp_source() {
  local archive="$ARCHIVE_ROOT/llama.cpp-$LLAMA_CPP_COMMIT.tar.gz"
  local destination="$SOURCE_ROOT/llama.cpp-$LLAMA_CPP_COMMIT"

  if [[ ! -f "$destination/include/llama.h" ]]; then
    download_locked_source llama-cpp "$LOCK_FILE" "$archive"
    /bin/mkdir -p "$SOURCE_ROOT"
    /bin/rm -rf "$destination"
    /usr/bin/tar -xzf "$archive" -C "$SOURCE_ROOT"
  fi
  printf '%s\n' "$destination"
}

LLAMA_CPP_ROOT="${LLAMA_CPP_ROOT:-$(prepare_llama_cpp_source)}"

if [[ ! -x "$C_COMPILER" || ! -x "$CXX_COMPILER" || ! -x "$LIBTOOL" || ! -x "$LIPO" ]]; then
  echo "Xcode C++/libtool/lipo tools are required" >&2
  exit 1
fi
if [[ ! -f "$LLAMA_CPP_ROOT/include/llama.h" ]]; then
  echo "missing pinned llama.cpp source tree: $LLAMA_CPP_ROOT" >&2
  exit 1
fi

LLAMA_CPP_ENGINE_VERSION="${LLAMA_CPP_COMMIT}+local-adapter-v2"

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
  inference/core/cancel_arbiter.cpp
  inference/core/engine_registry.cpp
  inference/core/token_stream.cpp
  inference/backends/llama_cpp/llama_cpp_api.cpp
  inference/backends/llama_cpp/llama_cpp_engine.cpp
  inference/backends/llama_cpp/llama_cpp_prompt.cpp
)
VENDOR_ARCHIVES=(
  libllama.a
  libmtmd.a
  libllama-common.a
  libllama-common-base.a
  libggml.a
  libggml-base.a
  libggml-cpu.a
  libggml-metal.a
  libggml-blas.a
)

ensure_vendor_archives() {
  local vendor_build="$1"
  local vendor_build_root="$LLAMA_CPP_ROOT/$vendor_build"
  if [[ -d "$vendor_build_root" ]] \
    && find "$vendor_build_root" -type f -name libmtmd.a -path '*/Release*/*' -print -quit \
      | grep -q . \
    && find "$vendor_build_root" -type f -name libllama-common.a -path '*/Release*/*' -print -quit \
      | grep -q .
  then
    return
  fi

  local platform_args=()
  case "$vendor_build" in
    build-macos)
      platform_args=(
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
      )
      ;;
    build-ios-sim)
      platform_args=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_SYSROOT=iphonesimulator
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
      )
      ;;
    build-ios-device)
      platform_args=(
        -DCMAKE_SYSTEM_NAME=iOS
        -DCMAKE_OSX_SYSROOT=iphoneos
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
      )
      ;;
    *)
      echo "unsupported llama.cpp vendor build: $vendor_build" >&2
      exit 1
      ;;
  esac

  rm -rf "$vendor_build_root"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    cmake -G Xcode -S "$LLAMA_CPP_ROOT" -B "$vendor_build_root" \
      -DLLAMA_BUILD_TOOLS=ON \
      -DLLAMA_BUILD_COMMON=ON \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=OFF \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF \
      -DGGML_OPENMP=OFF \
      "-DCMAKE_C_COMPILER=$C_COMPILER" \
      "-DCMAKE_CXX_COMPILER=$CXX_COMPILER" \
      "${platform_args[@]}"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    cmake --build "$vendor_build_root" --config Release --target mtmd
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    cmake --build "$vendor_build_root" --config Release --target llama-common
}

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
    "$CXX_COMPILER" -std=c++17 -O2 -fvisibility=hidden \
      -target "$target" -isysroot "$sdk_path" \
      -DLOCAL_AGENT_ENABLE_LLAMA_CPP \
      -DLOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD \
      -DLOCAL_AGENT_ENABLE_LLAMA_CPP_NATIVE_TOOLS \
      "-DLOCAL_AGENT_LLAMA_CPP_VERSION=\"$LLAMA_CPP_ENGINE_VERSION\"" \
      -I "$ROOT/inference/include" \
      -I "$ROOT/inference/core" \
      -I "$ROOT/inference/backends/llama_cpp" \
      -I "$LLAMA_CPP_ROOT/include" \
      -I "$LLAMA_CPP_ROOT/ggml/include" \
      -I "$LLAMA_CPP_ROOT/tools/mtmd" \
      -I "$LLAMA_CPP_ROOT/common" \
      -I "$LLAMA_CPP_ROOT/vendor" \
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
ensure_vendor_archives build-macos
ensure_vendor_archives build-ios-sim
ensure_vendor_archives build-ios-device
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
