#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test integration
