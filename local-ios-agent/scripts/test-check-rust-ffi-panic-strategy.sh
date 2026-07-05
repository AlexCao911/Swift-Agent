#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${SCRIPT_DIR}/check-rust-ffi-panic-strategy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_root() {
  local name="$1"
  mkdir -p "${TMP_DIR}/${name}/rust-core"
  cat > "${TMP_DIR}/${name}/rust-core/Cargo.toml" <<'TOML'
[package]
name = "local_ios_agent_runtime"
version = "0.1.0"
edition = "2021"

[lib]
name = "local_ios_agent_runtime"
path = "src/lib.rs"
crate-type = ["rlib", "staticlib"]
TOML
}

make_root allows_missing_profile
"${CHECKER}" "${TMP_DIR}/allows_missing_profile"

make_root allows_unwind
cat >> "${TMP_DIR}/allows_unwind/rust-core/Cargo.toml" <<'TOML'

[profile.release]
panic = "unwind"
TOML
"${CHECKER}" "${TMP_DIR}/allows_unwind"

make_root rejects_abort
cat >> "${TMP_DIR}/rejects_abort/rust-core/Cargo.toml" <<'TOML'

[profile.release]
panic = "abort"
TOML
if "${CHECKER}" "${TMP_DIR}/rejects_abort"; then
  echo "expected checker to reject profile.release panic=abort" >&2
  exit 1
fi

make_root rejects_rustflags
mkdir -p "${TMP_DIR}/rejects_rustflags/.cargo"
cat > "${TMP_DIR}/rejects_rustflags/.cargo/config.toml" <<'TOML'
[build]
rustflags = ["-C", "panic=abort"]
TOML
if "${CHECKER}" "${TMP_DIR}/rejects_rustflags"; then
  echo "expected checker to reject -C panic=abort rustflags" >&2
  exit 1
fi

echo "panic strategy checker contract passed"
