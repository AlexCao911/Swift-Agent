#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$ROOT/third_party/llama.cpp}"
BUILD_DIR="${LOCAL_AGENT_LLAMA_CPP_MTMD_BUILD_DIR:-/private/tmp/local-agent-llama-cpp-mtmd-ios-sim}"
CONFIGURATION="${LOCAL_AGENT_LLAMA_CPP_CONFIGURATION:-Release}"
CPU_ONLY="${LOCAL_AGENT_LLAMA_CPP_SIM_CPU_ONLY:-1}"

if [[ ! -f "$LLAMA_CPP_DIR/CMakeLists.txt" ]]; then
  echo "Missing llama.cpp checkout at $LLAMA_CPP_DIR" >&2
  exit 2
fi

if [[ ! -f "$LLAMA_CPP_DIR/tools/mtmd/mtmd.h" ]]; then
  echo "Missing mtmd headers in $LLAMA_CPP_DIR/tools/mtmd" >&2
  exit 2
fi

cmake_options=(
  -DCMAKE_C_COMPILER="$(xcrun --sdk iphonesimulator --find clang)"
  -DCMAKE_CXX_COMPILER="$(xcrun --sdk iphonesimulator --find clang++)"
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_TOOLS=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_SERVER=OFF
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.4
  -DIOS=ON
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT=iphonesimulator
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator
  -DLLAMA_OPENSSL=OFF
)

if [[ "$CPU_ONLY" == "1" ]]; then
  cmake_options+=(
    -DGGML_METAL=OFF
    -DGGML_ACCELERATE=OFF
    -DGGML_BLAS=OFF
    -DGGML_BLAS_VENDOR=Generic
  )
else
  cmake_options+=(
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_METAL=ON
    -DGGML_METAL_USE_BF16=ON
  )
fi

cmake -B "$BUILD_DIR" -G Xcode "${cmake_options[@]}" -S "$LLAMA_CPP_DIR"
cmake --build "$BUILD_DIR" --config "$CONFIGURATION" --target mtmd -- -quiet

llama_libs=(
  "$BUILD_DIR/src/$CONFIGURATION-iphonesimulator/libllama.a"
  "$BUILD_DIR/ggml/src/$CONFIGURATION-iphonesimulator/libggml.a"
  "$BUILD_DIR/ggml/src/$CONFIGURATION-iphonesimulator/libggml-base.a"
  "$BUILD_DIR/ggml/src/$CONFIGURATION-iphonesimulator/libggml-cpu.a"
)

if [[ "$CPU_ONLY" != "1" ]]; then
  llama_libs+=(
    "$BUILD_DIR/ggml/src/ggml-metal/$CONFIGURATION-iphonesimulator/libggml-metal.a"
    "$BUILD_DIR/ggml/src/ggml-blas/$CONFIGURATION-iphonesimulator/libggml-blas.a"
  )
fi

for library in "${llama_libs[@]}" "$BUILD_DIR/tools/mtmd/$CONFIGURATION-iphonesimulator/libmtmd.a"; do
  if [[ ! -f "$library" ]]; then
    echo "Expected build artifact missing: $library" >&2
    exit 2
  fi
done

combined="$BUILD_DIR/libllama_all.a"
xcrun libtool -static -o "$combined" "${llama_libs[@]}"

thin_or_copy() {
  local input="$1"
  local output="$2"
  local info
  info="$(lipo -info "$input")"
  if [[ "$info" == *"arm64"* && "$info" == *"x86_64"* ]]; then
    lipo "$input" -thin arm64 -output "$output"
  else
    cp "$input" "$output"
  fi
}

llama_arm64="$BUILD_DIR/libllama_all_arm64.a"
mtmd_arm64="$BUILD_DIR/libmtmd_arm64.a"
thin_or_copy "$combined" "$llama_arm64"
thin_or_copy "$BUILD_DIR/tools/mtmd/$CONFIGURATION-iphonesimulator/libmtmd.a" "$mtmd_arm64"

cat <<EOF
export LLAMA_CPP_HEADERS="$LLAMA_CPP_DIR/include:$LLAMA_CPP_DIR/ggml/include"
export LLAMA_CPP_LIBRARY="$llama_arm64"
export LLAMA_CPP_MTMD_HEADERS="$LLAMA_CPP_DIR/tools/mtmd"
export LLAMA_CPP_MTMD_LIBRARY="$mtmd_arm64"
export LOCAL_AGENT_LOCAL_INFERENCE_FEATURES="link-llama-cpp-mtmd-local-inference"
EOF
