#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON:?set LOCAL_AGENT_SIMULATOR_MODEL_CONFIG_JSON}"
: "${SIMULATOR_UDID:?set SIMULATOR_UDID}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild -quiet \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  test
