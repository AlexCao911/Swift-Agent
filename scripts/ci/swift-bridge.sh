#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CI_HOME="$ROOT/.ci-home"
CLANG_CACHE="$ROOT/local-ios-agent/toolkit/.build/clang-module-cache"

cd "$ROOT/local-ios-agent/rust-core"
cargo build

mkdir -p "$CI_HOME" "$CLANG_CACHE"

cd "$ROOT/local-ios-agent/toolkit"
HOME="$CI_HOME" CLANG_MODULE_CACHE_PATH="$CLANG_CACHE" swift test --disable-sandbox --scratch-path .build/ci
