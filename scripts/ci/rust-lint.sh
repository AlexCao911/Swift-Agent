#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo fmt --check
cargo clippy --all-targets --no-default-features -- -A clippy::never_loop
cargo test --test lint
