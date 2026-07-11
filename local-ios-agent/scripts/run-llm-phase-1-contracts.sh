#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

export CARGO_NET_OFFLINE=true

cargo test --manifest-path "${ROOT_DIR}/rust-core/Cargo.toml"
cargo test --manifest-path "${ROOT_DIR}/rust-core/Cargo.toml" --test lint
cargo build --manifest-path "${ROOT_DIR}/rust-core/Cargo.toml"
swift test --package-path "${ROOT_DIR}/toolkit"
"${ROOT_DIR}/scripts/test-check-rust-ffi-panic-strategy.sh"
