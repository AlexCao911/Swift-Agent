#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 SIGNED_JSON ENVELOPE_JSON [KEY_RING_JSON]" >&2
  exit 2
fi

if [[ -z "${CLOUD_CAPABILITY_CATALOG_SIGNING_SEED:-}" ]]; then
  echo "CLOUD_CAPABILITY_CATALOG_SIGNING_SEED is required" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/local-agent-clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"

if [[ $# -eq 3 ]]; then
  xcrun swift run --disable-sandbox --package-path "$repo_root/toolkit" \
    CloudCapabilityCatalogSigner "$1" "$2" "$3"
else
  xcrun swift run --disable-sandbox --package-path "$repo_root/toolkit" \
    CloudCapabilityCatalogSigner "$1" "$2"
fi
