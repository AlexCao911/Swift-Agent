#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test contract
cargo test --test contract --features builtin-openai-compatible compiled_list_includes_openai_provider_when_feature_is_enabled
