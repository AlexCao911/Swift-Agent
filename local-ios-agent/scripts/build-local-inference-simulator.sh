#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON:?set LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON}"
: "${SIMULATOR_UDID:?set SIMULATOR_UDID}"

FEATURES="${LOCAL_AGENT_LOCAL_INFERENCE_FEATURES:-link-llama-cpp-local-inference}"
if [[ "$FEATURES" == *"link-llama-cpp"* ]]; then
  : "${LLAMA_CPP_HEADERS:?set LLAMA_CPP_HEADERS}"
  if [[ -z "${LLAMA_CPP_LIBRARY:-}" && -z "${LLAMA_CPP_XCFRAMEWORK:-}" ]]; then
    echo "set LLAMA_CPP_LIBRARY or LLAMA_CPP_XCFRAMEWORK" >&2
    exit 2
  fi
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
cargo build \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --target aarch64-apple-ios-sim \
  --features "$FEATURES"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild -quiet \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -derivedDataPath "${LOCAL_AGENT_DERIVED_DATA_PATH:-/private/tmp/local-agent-deriveddata}" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test
