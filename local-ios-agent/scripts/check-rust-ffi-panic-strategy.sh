#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FAILED=0

check_manifest() {
  local manifest="$1"
  [[ -f "${manifest}" ]] || return 0

  if awk '
    BEGIN { in_release = 0; found_abort = 0 }
    /^\[profile\.release\]/ { in_release = 1; next }
    /^\[/ { in_release = 0 }
    in_release && /^[[:space:]]*panic[[:space:]]*=/ {
      line = $0
      gsub(/[[:space:]\047"]/, "", line)
      split(line, parts, "=")
      if (parts[2] == "abort") {
        found_abort = 1
      }
    }
    END { exit found_abort ? 42 : 0 }
  ' "${manifest}"; then
    return 0
  fi

  echo "error: ${manifest} sets [profile.release] panic = \"abort\"" >&2
  FAILED=1
}

check_config() {
  local config="$1"
  [[ -f "${config}" ]] || return 0
  if grep -Eq 'panic[[:space:]]*=[[:space:]]*"?abort"?|-C[[:space:]]*panic=abort|panic=abort' "${config}"; then
    echo "error: ${config} configures panic=abort rustflags" >&2
    FAILED=1
  fi
}

check_manifest "${ROOT}/Cargo.toml"
check_manifest "${ROOT}/rust-core/Cargo.toml"
check_manifest "${ROOT}/../Cargo.toml"

check_config "${ROOT}/.cargo/config.toml"
check_config "${ROOT}/.cargo/config"
check_config "${ROOT}/rust-core/.cargo/config.toml"
check_config "${ROOT}/rust-core/.cargo/config"
check_config "${ROOT}/../.cargo/config.toml"
check_config "${ROOT}/../.cargo/config"

if [[ "${FAILED}" -ne 0 ]]; then
  exit 1
fi

echo "Rust Swift FFI panic strategy check passed"
