#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

"$ROOT/scripts/ci/rust-unit.sh"
"$ROOT/scripts/ci/rust-lint.sh"
"$ROOT/scripts/ci/rust-contract.sh"
"$ROOT/scripts/ci/rust-golden.sh"
"$ROOT/scripts/ci/rust-integration.sh"
"$ROOT/scripts/ci/swift-bridge.sh"
