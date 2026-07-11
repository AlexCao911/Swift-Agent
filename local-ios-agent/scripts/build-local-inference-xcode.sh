#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_AGENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCFRAMEWORK="$LOCAL_AGENT_ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework"
STAGING_DIRECTORY="$LOCAL_AGENT_ROOT/rust-core/target/xcode-ios"
CARGO_BIN="${CARGO:-$HOME/.cargo/bin/cargo}"
if [[ ! -x "$CARGO_BIN" ]]; then
  CARGO_BIN="$(command -v cargo || true)"
fi
if [[ -z "$CARGO_BIN" || ! -x "$CARGO_BIN" ]]; then
  echo "error: cargo is required to build the Rust runtime" >&2
  exit 1
fi

case "${PLATFORM_NAME:-iphonesimulator}" in
  iphonesimulator)
    RUST_TARGET="aarch64-apple-ios-sim"
    ;;
  iphoneos)
    RUST_TARGET="aarch64-apple-ios"
    ;;
  *)
    echo "error: unsupported Xcode platform for the iOS Rust runtime: ${PLATFORM_NAME:-unset}" >&2
    exit 1
    ;;
esac

PROFILE_DIRECTORY="debug"
CARGO_ARGUMENTS=(
  build
  --manifest-path "$LOCAL_AGENT_ROOT/rust-core/Cargo.toml"
  --target "$RUST_TARGET"
  --features link-llama-cpp-local-inference
)
if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
  CARGO_ARGUMENTS+=(--release)
  PROFILE_DIRECTORY="release"
fi

"$LOCAL_AGENT_ROOT/scripts/build-local-agent-inference-xcframework.sh"

SDKROOT="${SDKROOT:-}" \
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" \
LOCAL_AGENT_INFERENCE_XCFRAMEWORK="$XCFRAMEWORK" \
"$CARGO_BIN" build \
  "${CARGO_ARGUMENTS[@]:1}"

mkdir -p "$STAGING_DIRECTORY"
cp "$LOCAL_AGENT_ROOT/rust-core/target/$RUST_TARGET/$PROFILE_DIRECTORY/liblocal_ios_agent_runtime.a" \
  "$STAGING_DIRECTORY/liblocal_ios_agent_runtime.a"
