#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
XCRESULTTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/xcresulttool"
DERIVED_DATA="${LOCAL_AGENT_PHASE2_RELEASE_DERIVED_DATA:-/private/tmp/local-agent-phase2-release-smoke}"
IPHONE_DESTINATION="${LOCAL_AGENT_PHASE2_RELEASE_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}"
IPAD_DESTINATION="${LOCAL_AGENT_PHASE2_RELEASE_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest}"

require_environment() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "missing required release-smoke environment variable: $name" >&2
    exit 2
  fi
}

for name in \
  LOCAL_AGENT_PHASE2_RELEASE_CATALOG_PATH \
  LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT \
  LOCAL_AGENT_PHASE2_RELEASE_ENGINE_ID \
  LOCAL_AGENT_PHASE2_RELEASE_MODEL_ID
do
  require_environment "$name"
done

if [[ ! -f "$LOCAL_AGENT_PHASE2_RELEASE_CATALOG_PATH" ]]; then
  echo "release catalog does not exist: $LOCAL_AGENT_PHASE2_RELEASE_CATALOG_PATH" >&2
  exit 2
fi
if [[ ! -d "$LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT" ]]; then
  echo "verified installation root does not exist: $LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT" >&2
  exit 2
fi

"$ROOT/scripts/build-local-agent-inference-xcframework.sh"
mkdir -p "$DERIVED_DATA"

run_smoke() {
  local destination="$1"
  local derived="$2"
  local result_bundle="$derived/release-smoke-$(/usr/bin/uuidgen).xcresult"
  local test_count
  "$XCODEBUILD" -quiet \
    -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
    -scheme LocalAgentApp \
    -configuration Release \
    -destination "$destination" \
    -derivedDataPath "$derived" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG \
    "LOCAL_AGENT_RUN_PHASE2_RELEASE_SMOKE=1" \
    "LOCAL_AGENT_PHASE2_RELEASE_CATALOG_PATH=$LOCAL_AGENT_PHASE2_RELEASE_CATALOG_PATH" \
    "LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT=$LOCAL_AGENT_PHASE2_RELEASE_INSTALLATION_ROOT" \
    "LOCAL_AGENT_PHASE2_RELEASE_ENGINE_ID=$LOCAL_AGENT_PHASE2_RELEASE_ENGINE_ID" \
    "LOCAL_AGENT_PHASE2_RELEASE_MODEL_ID=$LOCAL_AGENT_PHASE2_RELEASE_MODEL_ID" \
    test -only-testing:LocalAgentAppTests/LocalInferenceReleaseSmokeTests
  test_count="$(
    "$XCRESULTTOOL" get test-results summary --path "$result_bundle" \
      | /usr/bin/plutil -extract totalTestCount raw -o - -
  )"
  if [[ "$test_count" != "1" ]]; then
    echo "release smoke must execute exactly one test, observed: $test_count" >&2
    exit 1
  fi
}

run_smoke "$IPHONE_DESTINATION" "$DERIVED_DATA/iphone"
run_smoke "$IPAD_DESTINATION" "$DERIVED_DATA/ipad"
"$ROOT/scripts/test-local-inference-app-link.sh" --require-catalog-resources

echo "LLM Phase 2 release smoke passed on iPhone and iPad Simulator"
