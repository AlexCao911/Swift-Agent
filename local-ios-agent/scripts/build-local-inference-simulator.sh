#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON:?set LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON}"
: "${SIMULATOR_UDID:?set SIMULATOR_UDID}"

DEFAULT_FEATURES="link-llama-cpp-local-inference"
if [[ -n "${LOCAL_AGENT_SIMULATOR_MMPROJ:-}" ]]; then
  DEFAULT_FEATURES="link-llama-cpp-mtmd-local-inference"
fi
FEATURES="${LOCAL_AGENT_LOCAL_INFERENCE_FEATURES:-$DEFAULT_FEATURES}"
if [[ "$FEATURES" == *"link-llama-cpp"* ]]; then
  : "${LLAMA_CPP_HEADERS:?set LLAMA_CPP_HEADERS}"
  if [[ -z "${LLAMA_CPP_LIBRARY:-}" && -z "${LLAMA_CPP_XCFRAMEWORK:-}" ]]; then
    echo "set LLAMA_CPP_LIBRARY or LLAMA_CPP_XCFRAMEWORK" >&2
    exit 2
  fi
fi
if [[ "$FEATURES" == *"link-llama-cpp-mtmd-local-inference"* ]]; then
  : "${LLAMA_CPP_MTMD_HEADERS:?set LLAMA_CPP_MTMD_HEADERS}"
  : "${LLAMA_CPP_MTMD_LIBRARY:?set LLAMA_CPP_MTMD_LIBRARY}"
  if [[ -z "${LLAMA_CPP_LIBRARY:-}" ]]; then
    echo "set LLAMA_CPP_LIBRARY to a combined static llama.cpp archive for mtmd simulator builds" >&2
    echo "hint: run scripts/build-llama-cpp-mtmd-ios-simulator.sh and eval its exported paths" >&2
    exit 2
  fi
fi

SDKROOT="${SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk}" \
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" \
cargo build \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --target aarch64-apple-ios-sim \
  --features "$FEATURES"

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -quiet \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -derivedDataPath "${LOCAL_AGENT_DERIVED_DATA_PATH:-/private/tmp/local-agent-deriveddata}" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test
