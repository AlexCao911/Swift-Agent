#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="$ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework"
DERIVED_DATA="${LOCAL_AGENT_LINK_TEST_DERIVED_DATA:-/private/tmp/local-agent-inference-link-derived}"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
NM="/usr/bin/nm"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
MODULE_CACHE="${LOCAL_AGENT_LINK_TEST_MODULE_CACHE:-/private/tmp/local-agent-inference-link-module-cache}"
mkdir -p "$DERIVED_DATA" "$MODULE_CACHE"

require_text() {
  local needle="$1"
  local file="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "missing required text in $file: $needle" >&2
    exit 1
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

fail() {
  echo "$1" >&2
  exit 1
}

run_xcodebuild() {
  local log="$1"
  shift
  if ! CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    "$XCODEBUILD" -quiet "$@" >"$log" 2>&1; then
    tail -200 "$log" >&2
    return 1
  fi
}

assert_complete_native_abi() {
  local binary="$1"
  require_file "$binary"
  local symbol
  local count
  for symbol in \
    local_agent_link_anchor \
    local_agent_string_free \
    local_agent_engine_list \
    local_agent_engine_create \
    local_agent_engine_capabilities \
    local_agent_engine_release \
    local_agent_model_load \
    local_agent_model_unload \
    local_agent_generation_start \
    local_agent_generation_read \
    local_agent_generation_cancel \
    local_agent_generation_release \
    local_agent_last_error
  do
    count="$("$NM" "$binary" 2>/dev/null | awk -v wanted="_$symbol" \
      '$2 ~ /^[Tt]$/ && $3 == wanted { count += 1 } END { print count + 0 }')"
    if [[ "$count" != "1" ]]; then
      fail "$binary must contain exactly one definition of $symbol; found $count"
    fi
  done

  if "$NM" -u "$binary" 2>/dev/null | grep -E '_(llama|ggml)_' >/dev/null; then
    fail "$binary contains unresolved llama.cpp/ggml vendor symbols"
  fi
}

require_text '.binaryTarget(' "$ROOT/toolkit/Package.swift"
require_text 'name: "LocalAgentInferenceNative"' "$ROOT/toolkit/Package.swift"
require_text 'path: "Artifacts/LocalAgentInferenceNative.xcframework"' "$ROOT/toolkit/Package.swift"
require_text 'rust-core/target/xcode-ios' "$ROOT/toolkit/Package.swift"
if grep -Fq 'aarch64-apple-ios-sim/debug' "$ROOT/toolkit/Package.swift"; then
  echo "Package.swift must not hard-code a Simulator Rust library for every iOS build" >&2
  exit 1
fi
require_text 'aarch64-apple-ios-sim' "$ROOT/scripts/build-local-inference-xcode.sh"
require_text 'aarch64-apple-ios' "$ROOT/scripts/build-local-inference-xcode.sh"
require_text 'target/xcode-ios' "$ROOT/scripts/build-local-inference-xcode.sh"
require_text 'rev-parse --path-format=absolute --git-common-dir' \
  "$ROOT/scripts/build-local-agent-inference-xcframework.sh"
require_text 'plutil -extract engine_ids' \
  "$ROOT/scripts/build-local-agent-inference-xcframework.sh"
require_file "$ROOT/inference/release-engines.json"
require_text '"llama_cpp"' "$ROOT/inference/release-engines.json"
require_file "$ARTIFACT/Info.plist"
require_file "$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
require_text 'name: "LocalAgentLLMLocal"' "$ROOT/toolkit/Package.swift"
require_text 'dependencies: ["LocalAgentLLMContracts", "LocalAgentLLMCore", "CSQLite", "LocalAgentInferenceNative"]' \
  "$ROOT/toolkit/Package.swift"
require_text 'import LocalAgentInferenceNative' \
  "$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
require_text 'local_agent_engine_capabilities(engine, &output)' \
  "$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
require_text 'LocalInferenceNativeLinkProbe.requireAllExports()' \
  "$ROOT/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift"

native_imports="$(grep -RIl '^import LocalAgentInferenceNative$' \
  "$ROOT/toolkit/Sources" || true)"
expected_import="$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
if [[ "$native_imports" != "$expected_import" ]]; then
  fail "LocalAgentInferenceNative must be imported only by $expected_import; found: $native_imports"
fi

"$ROOT/scripts/build-local-agent-inference-xcframework.sh"

LOCAL_AGENT_INFERENCE_XCFRAMEWORK="$ARTIFACT" \
  cargo build --manifest-path "$ROOT/rust-core/Cargo.toml" \
    --features link-llama-cpp-local-inference
RUST_ARCHIVE="$ROOT/rust-core/target/debug/liblocal_ios_agent_runtime.a"
require_file "$RUST_ARCHIVE"
rust_symbols="$("$NM" "$RUST_ARCHIVE" 2>/dev/null || true)"
if printf '%s\n' "$rust_symbols" | grep -E ' [Tt] _local_agent_(engine|model|generation|string|last_error)' >/dev/null; then
  fail "Rust staticlib must not define the local inference C ABI"
fi
if ! printf '%s\n' "$rust_symbols" | grep ' U _local_agent_engine_create' >/dev/null; then
  fail "legacy Rust local inference must remain an unbundled consumer of the shared C ABI"
fi

DEVELOPER_DIR="$DEVELOPER_DIR" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  swift test --disable-sandbox \
    --package-path "$ROOT/toolkit" \
    --scratch-path "$DERIVED_DATA/swift" \
    --filter CppInferencePackagingTests

run_xcodebuild "$DERIVED_DATA/simulator.log" \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA/simulator" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 \
  build-for-testing
SIMULATOR_APP="$DERIVED_DATA/simulator/Build/Products/Debug-iphonesimulator/LocalAgentApp.app"
SIMULATOR_BINARY="$SIMULATOR_APP/LocalAgentApp.debug.dylib"
if [[ ! -f "$SIMULATOR_BINARY" ]]; then
  SIMULATOR_BINARY="$SIMULATOR_APP/LocalAgentApp"
fi
assert_complete_native_abi "$SIMULATOR_BINARY"

run_xcodebuild "$DERIVED_DATA/iphoneos.log" \
  -project "$ROOT/apps/LocalAgentApp/LocalAgentApp.xcodeproj" \
  -scheme LocalAgentApp \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA/iphoneos" \
  CODE_SIGNING_ALLOWED=NO \
  build
assert_complete_native_abi \
  "$DERIVED_DATA/iphoneos/Build/Products/Release-iphoneos/LocalAgentApp.app/LocalAgentApp"

echo "local inference package/link contract passed"
