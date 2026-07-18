#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="${LOCAL_AGENT_PHASE3_MODULE_CACHE:-/private/tmp/local-agent-phase3-module-cache}"
SWIFT_SCRATCH="${LOCAL_AGENT_PHASE3_SWIFT_SCRATCH:-/private/tmp/local-agent-phase3-swift}"
DERIVED_DATA="${LOCAL_AGENT_PHASE3_DERIVED_DATA:-/private/tmp/local-agent-phase3-derived}"

unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY XAI_API_KEY
unset DEEPSEEK_API_KEY MINIMAX_API_KEY ZHIPUAI_API_KEY

mkdir -p "$MODULE_CACHE" "$SWIFT_SCRATCH" "$DERIVED_DATA"

SIMULATOR_UDID="${LOCAL_AGENT_PHASE3_SIMULATOR_UDID:-}"
if [[ -z "$SIMULATOR_UDID" ]]; then
  SIMULATOR_UDID="$(
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      /usr/bin/xcrun \
        simctl list devices available \
      | /usr/bin/awk '
          /iPhone 17 Pro \([0-9A-Fa-f-]+\)/ && udid == "" {
            udid = $0
            sub(/^.*iPhone 17 Pro \(/, "", udid)
            sub(/\).*/, "", udid)
          }
          END { print udid }
        '
  )"
fi
if [[ ! "$SIMULATOR_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  echo "set LOCAL_AGENT_PHASE3_SIMULATOR_UDID to an available iPhone simulator UDID" >&2
  exit 2
fi

"$ROOT/scripts/run-llm-phase-2-contracts.sh"

CARGO_NET_OFFLINE=true cargo test \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --test lint llm_phase_three_architecture -- --nocapture

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
    test --disable-sandbox \
    --package-path "$ROOT/toolkit" \
    --scratch-path "$SWIFT_SCRATCH"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
    test \
    -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
    -scheme LocalAgentApp \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:LocalAgentAppTests/CloudCredentialKeychainTests

echo "LLM Phase 3 cloud product contracts passed"
