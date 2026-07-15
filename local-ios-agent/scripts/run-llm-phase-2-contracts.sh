#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE_CACHE="${LOCAL_AGENT_PHASE2_MODULE_CACHE:-/private/tmp/local-agent-phase2-module-cache}"
SWIFT_SCRATCH="${LOCAL_AGENT_PHASE2_SWIFT_SCRATCH:-/private/tmp/local-agent-phase2-swift}"

mkdir -p "$MODULE_CACHE" "$SWIFT_SCRATCH"

"$ROOT/scripts/build-local-agent-inference-xcframework.sh"
"$ROOT/scripts/run-llm-phase-1-contracts.sh"
"$ROOT/scripts/run-local-inference-cpp-contracts.sh"

CARGO_NET_OFFLINE=true cargo test \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  --test lint llm_phase_two_architecture -- --nocapture

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
    test --disable-sandbox \
    --package-path "$ROOT/toolkit" \
    --scratch-path "$SWIFT_SCRATCH"

"$ROOT/scripts/test-local-inference-app-link.sh" --require-catalog-resources

echo "LLM Phase 2 local product contracts passed"
