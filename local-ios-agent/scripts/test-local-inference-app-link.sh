#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="$ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework"
DERIVED_DATA="${LOCAL_AGENT_LINK_TEST_DERIVED_DATA:-/private/tmp/local-agent-inference-link-derived}"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
NM="/usr/bin/nm"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
MODULE_CACHE="${LOCAL_AGENT_LINK_TEST_MODULE_CACHE:-/private/tmp/local-agent-inference-link-module-cache}"
REQUIRE_CATALOG_RESOURCES=0
if [[ "${1:-}" == "--require-catalog-resources" ]]; then
  REQUIRE_CATALOG_RESOURCES=1
  shift
fi
if [[ $# -ne 0 ]]; then
  echo "usage: $0 [--require-catalog-resources]" >&2
  exit 2
fi
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
    local_agent_engine_parameter_schema \
    local_agent_engine_release \
    local_agent_model_validate \
    local_agent_model_load \
    local_agent_model_unload \
    local_agent_generation_start \
    local_agent_generation_validate \
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

assert_catalog_resources() {
  local app="$1"
  local catalog_count
  local key_count
  # build-for-testing embeds an independent test plug-in and its own SwiftPM
  # resource bundle inside PlugIns/. Count only the shipping App payload here.
  catalog_count="$(find "$app" -path "$app/PlugIns" -prune -o -name 'OfficialLocalModelCatalog.v1.json' -type f -print | wc -l | tr -d ' ')"
  key_count="$(find "$app" -path "$app/PlugIns" -prune -o -name 'OfficialLocalModelCatalogKeys.v1.json' -type f -print | wc -l | tr -d ' ')"
  if [[ "$catalog_count" != "1" || "$key_count" != "1" ]]; then
    fail "$app must embed exactly one signed local catalog and public key ring; found catalog=$catalog_count keys=$key_count"
  fi
}

assert_release_catalog_engine_sets() {
  local release_manifest="$ROOT/inference/release-engines.json"
  local catalog="$ROOT/toolkit/Sources/LocalAgentLLMLocal/Resources/OfficialLocalModelCatalog.v1.json"
  local release_count
  local catalog_count
  local release_ids=""
  local catalog_ids=""
  local index
  release_count="$(/usr/bin/plutil -extract engine_ids raw -o - "$release_manifest")"
  catalog_count="$(/usr/bin/plutil -extract signed.models raw -o - "$catalog")"
  if [[ "$release_count" -lt 1 || "$catalog_count" -lt 1 ]]; then
    fail "release engine manifest and official catalog must both be non-empty"
  fi
  for ((index = 0; index < release_count; index += 1)); do
    release_ids+="$(/usr/bin/plutil -extract "engine_ids.$index" raw -o - "$release_manifest")"$'\n'
  done
  for ((index = 0; index < catalog_count; index += 1)); do
    catalog_ids+="$(/usr/bin/plutil -extract "signed.models.$index.engine_id" raw -o - "$catalog")"$'\n'
  done
  release_ids="$(printf '%s' "$release_ids" | sort -u)"
  catalog_ids="$(printf '%s' "$catalog_ids" | sort -u)"
  if [[ "$release_ids" != "$catalog_ids" ]]; then
    fail "release engine IDs and official catalog engine IDs differ: release=[$release_ids] catalog=[$catalog_ids]"
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
require_text 'resources: [.process("Resources")]' "$ROOT/toolkit/Package.swift"
require_text 'dependencies: ["LocalAgentLLMContracts", "LocalAgentLLMCore", "CSQLite", "LocalAgentInferenceNative"]' \
  "$ROOT/toolkit/Package.swift"
require_text 'import LocalAgentInferenceNative' \
  "$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
require_text 'local_agent_engine_capabilities(engine, &output)' \
  "$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
require_text 'local_agent_link_anchor() == 15' \
  "$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
require_text 'LocalInferenceNativeLinkProbe.requireAllExports()' \
  "$ROOT/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift"
if [[ "$REQUIRE_CATALOG_RESOURCES" == "1" ]]; then
  assert_release_catalog_engine_sets
fi

native_imports="$(grep -RIl '^import LocalAgentInferenceNative$' \
  "$ROOT/toolkit/Sources" || true)"
expected_import="$ROOT/toolkit/Sources/LocalAgentLLMLocal/CppInferenceClient.swift"
if [[ "$native_imports" != "$expected_import" ]]; then
  fail "LocalAgentInferenceNative must be imported only by $expected_import; found: $native_imports"
fi

"$ROOT/scripts/build-local-agent-inference-xcframework.sh"

cargo build --manifest-path "$ROOT/rust-core/Cargo.toml"
RUST_ARCHIVE="$ROOT/rust-core/target/debug/liblocal_ios_agent_runtime.a"
require_file "$RUST_ARCHIVE"
rust_symbols="$("$NM" "$RUST_ARCHIVE" 2>/dev/null || true)"
if printf '%s\n' "$rust_symbols" | grep -E ' [Tt] _local_agent_(engine|model|generation|string|last_error)' >/dev/null; then
  fail "Rust staticlib must not define the local inference C ABI"
fi
if printf '%s\n' "$rust_symbols" | grep -E ' U _local_agent_(engine|model|generation|string|last_error)' >/dev/null; then
  fail "Rust staticlib must not consume the local inference C ABI"
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
if [[ "$REQUIRE_CATALOG_RESOURCES" == "1" ]]; then
  assert_catalog_resources "$SIMULATOR_APP"
fi

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
if [[ "$REQUIRE_CATALOG_RESOURCES" == "1" ]]; then
  assert_catalog_resources \
    "$DERIVED_DATA/iphoneos/Build/Products/Release-iphoneos/LocalAgentApp.app"
fi

echo "local inference package/link contract passed"
