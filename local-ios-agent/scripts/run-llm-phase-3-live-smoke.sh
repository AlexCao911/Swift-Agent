#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
required=(
  LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_ID
  LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_REVISION
  LOCAL_AGENT_CLOUD_SMOKE_MODEL_ID
  LOCAL_AGENT_CLOUD_SMOKE_CREDENTIAL_REF
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "missing required live-smoke variable: $name" >&2
    exit 2
  fi
done
if [[ ! "${LOCAL_AGENT_CLOUD_SMOKE_PROVIDER_PROFILE_REVISION}" =~ ^[1-9][0-9]*$ ]]; then
  echo "provider profile revision must be a positive canonical integer" >&2
  exit 2
fi

while IFS='=' read -r name _; do
  case "$name" in
    *_API_KEY|*_TOKEN|*_SECRET)
      echo "refusing live smoke while credential material is present in environment variable $name" >&2
      exit 2
      ;;
    LOCAL_AGENT_CLOUD_SMOKE_*) ;;
  esac
done < <(env)

LOCAL_AGENT_CLOUD_SMOKE_HOST_PROCESS_EPOCH="$(
  /usr/bin/openssl rand -base64 32 \
    | /usr/bin/tr '+/' '-_' \
    | /usr/bin/tr -d '='
)"
export LOCAL_AGENT_CLOUD_SMOKE_HOST_PROCESS_EPOCH

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
    run --package-path "$ROOT/toolkit" CloudProviderLiveSmoke
