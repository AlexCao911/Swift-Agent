#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/local-ios-agent/rust-core"
cargo test --test unit -- --skip localhost_transport_uses_content_length_and_does_not_wait_for_eof --test-threads=1

if [[ "${CODEX_SANDBOX_NETWORK_DISABLED:-0}" == "1" ]]; then
  echo "Skipping localhost socket unit test inside Codex network-disabled sandbox."
else
  cargo test --test unit localhost_transport_uses_content_length_and_does_not_wait_for_eof
fi
