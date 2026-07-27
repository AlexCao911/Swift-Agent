#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="${LOCAL_AGENT_PHASE4_MODULE_CACHE:-/private/tmp/local-agent-phase4-module-cache}"
SWIFT_SCRATCH="${LOCAL_AGENT_PHASE4_SWIFT_SCRATCH:-/private/tmp/local-agent-phase4-swift}"
DERIVED_DATA="${LOCAL_AGENT_PHASE4_DERIVED_DATA:-/private/tmp/local-agent-phase4-derived}"
IPHONE_UDID="${LOCAL_AGENT_PHASE4_IPHONE_UDID:-}"
IPAD_UDID="${LOCAL_AGENT_PHASE4_IPAD_UDID:-}"

unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY XAI_API_KEY
unset DEEPSEEK_API_KEY MINIMAX_API_KEY ZHIPUAI_API_KEY

if [[ ! "$IPHONE_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  echo "set LOCAL_AGENT_PHASE4_IPHONE_UDID to an available iPhone simulator UDID" >&2
  exit 2
fi
if [[ ! "$IPAD_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
  echo "set LOCAL_AGENT_PHASE4_IPAD_UDID to an available iPad simulator UDID" >&2
  exit 2
fi
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices available \
  | /usr/bin/grep -F "($IPHONE_UDID)" \
  | /usr/bin/grep -Fq "iPhone"; then
  echo "LOCAL_AGENT_PHASE4_IPHONE_UDID is not an available iPhone simulator" >&2
  exit 2
fi
if ! DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun simctl list devices available \
  | /usr/bin/grep -F "($IPAD_UDID)" \
  | /usr/bin/grep -Fq "iPad"; then
  echo "LOCAL_AGENT_PHASE4_IPAD_UDID is not an available iPad simulator" >&2
  exit 2
fi

mkdir -p "$MODULE_CACHE" "$SWIFT_SCRATCH" "$DERIVED_DATA"
export LOCAL_AGENT_PHASE3_SIMULATOR_UDID="$IPHONE_UDID"

"$ROOT/scripts/run-llm-phase-3-contracts.sh"

CARGO_NET_OFFLINE=true cargo test \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --lib
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --test contract
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --test integration
CARGO_NET_OFFLINE=true cargo test \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --test lint llm_phase_four_architecture -- --nocapture

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
    test --disable-sandbox \
    --package-path "$ROOT/toolkit" \
    --scratch-path "$SWIFT_SCRATCH"

for UDID in "$IPHONE_UDID" "$IPAD_UDID"; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
      test \
      -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
      -scheme LocalAgentApp \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$DERIVED_DATA-$UDID" \
      -only-testing:LocalAgentAppTests/LLMHostCompositionTests
done

echo "LLM Phase 4 host execution contracts passed"
