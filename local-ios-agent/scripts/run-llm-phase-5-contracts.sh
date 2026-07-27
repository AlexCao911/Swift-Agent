#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPHONE_UDID="${LOCAL_AGENT_PHASE5_IPHONE_UDID:-}"
IPAD_UDID="${LOCAL_AGENT_PHASE5_IPAD_UDID:-}"
DERIVED_DATA="${LOCAL_AGENT_PHASE5_DERIVED_DATA:-/private/tmp/local-agent-phase5-derived}"

if [[ -z "$IPHONE_UDID" || -z "$IPAD_UDID" ]]; then
  echo "Set LOCAL_AGENT_PHASE5_IPHONE_UDID and LOCAL_AGENT_PHASE5_IPAD_UDID." >&2
  exit 2
fi

unset OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY XAI_API_KEY
unset DEEPSEEK_API_KEY MINIMAX_API_KEY ZHIPUAI_API_KEY

LOCAL_AGENT_PHASE4_IPHONE_UDID="$IPHONE_UDID" \
LOCAL_AGENT_PHASE4_IPAD_UDID="$IPAD_UDID" \
  "$ROOT/scripts/run-llm-phase-4-contracts.sh"

for UDID in "$IPHONE_UDID" "$IPAD_UDID"; do
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
      -quiet \
      -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
      -scheme LocalAgentApp \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$DERIVED_DATA-$UDID" \
      -only-testing:LocalAgentAppTests/ModelCenterViewModelTests \
      -only-testing:LocalAgentAppTests/ProviderProfileEditorTests \
      -only-testing:LocalAgentAppTests/AppCloudApprovalBrokerTests \
      -only-testing:LocalAgentAppTests/HostBoundAgentPublishTests \
      -only-testing:LocalAgentAppTests/LegacyLLMMigrationCoordinatorTests \
      -only-testing:LocalAgentAppTests/LLMProductBootstrapTests \
      -only-testing:LocalAgentAppTests/LLMHostCompositionTests \
      SWIFT_ENABLE_BATCH_MODE=NO
done
