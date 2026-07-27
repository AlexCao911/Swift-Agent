#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON:?set LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON}"
: "${SIMULATOR_UDID:?set SIMULATOR_UDID}"

"$ROOT/scripts/build-local-agent-inference-xcframework.sh"

SDKROOT="${SDKROOT:-/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk}" \
IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" \
cargo build \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --target aarch64-apple-ios-sim

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -quiet \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -derivedDataPath "${LOCAL_AGENT_DERIVED_DATA_PATH:-/private/tmp/local-agent-deriveddata}" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test
