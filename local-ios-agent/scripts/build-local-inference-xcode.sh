#!/usr/bin/env bash
set -euo pipefail

if [[ "${PLATFORM_NAME:-iphonesimulator}" != "iphonesimulator" ]]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_AGENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTS_ROOT="$(cd "$LOCAL_AGENT_ROOT/../.." && pwd)"
DEFAULT_LLAMA_CPP_ROOT="$PROJECTS_ROOT/minicpmv-town/third_party/llama.cpp"

LLAMA_CPP_XCFRAMEWORK="${LLAMA_CPP_XCFRAMEWORK:-$DEFAULT_LLAMA_CPP_ROOT/build-apple/llama.xcframework}"
LLAMA_CPP_HEADERS="${LLAMA_CPP_HEADERS:-$DEFAULT_LLAMA_CPP_ROOT/include:$DEFAULT_LLAMA_CPP_ROOT/ggml/include}"
CARGO_BIN="${CARGO:-$HOME/.cargo/bin/cargo}"
if [[ ! -x "$CARGO_BIN" ]]; then
  CARGO_BIN="$(command -v cargo || true)"
fi
if [[ -z "$CARGO_BIN" || ! -x "$CARGO_BIN" ]]; then
  echo "error: cargo is required to build the Rust runtime" >&2
  exit 1
fi

SDKROOT="${SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk}"
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

build_default_runtime() {
  SDKROOT="$SDKROOT" \
  IPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
  "$CARGO_BIN" build \
    --manifest-path "$LOCAL_AGENT_ROOT/rust-core/Cargo.toml" \
    --target aarch64-apple-ios-sim
}

if [[ ! -d "$LLAMA_CPP_XCFRAMEWORK" ]]; then
  echo "warning: llama.cpp xcframework not found at $LLAMA_CPP_XCFRAMEWORK; building runtime without local llama.cpp" >&2
  build_default_runtime
  exit 0
fi

IFS=: read -r LLAMA_CPP_INCLUDE_DIR LLAMA_CPP_GGML_INCLUDE_DIR <<< "$LLAMA_CPP_HEADERS"
if [[ ! -d "$LLAMA_CPP_INCLUDE_DIR" || ! -d "$LLAMA_CPP_GGML_INCLUDE_DIR" ]]; then
  echo "warning: llama.cpp headers not found at $LLAMA_CPP_HEADERS; building runtime without local llama.cpp" >&2
  build_default_runtime
  exit 0
fi

SDKROOT="$SDKROOT" \
IPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
LLAMA_CPP_HEADERS="$LLAMA_CPP_HEADERS" \
LLAMA_CPP_XCFRAMEWORK="$LLAMA_CPP_XCFRAMEWORK" \
"$CARGO_BIN" build \
  --manifest-path "$LOCAL_AGENT_ROOT/rust-core/Cargo.toml" \
  --target aarch64-apple-ios-sim \
  --features link-llama-cpp-local-inference
