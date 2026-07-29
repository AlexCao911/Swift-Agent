#!/usr/bin/env bash
set -euo pipefail

LOCALAGENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_ROOT="$LOCALAGENT_ROOT/ThirdParty/OpenMinisNative"
LOCK_FILE="$NATIVE_ROOT/native-sources.lock"

# shellcheck source=./native/common.sh
source "$LOCALAGENT_ROOT/scripts/native/common.sh"

fail() {
    echo "native.contract_failed: $*" >&2
    exit 1
}

assert_lock_record() {
    local name="$1"
    local expected_version="$2"
    local record
    record="$(native_source_record "$name" "$LOCK_FILE")"
    IFS='|' read -r actual_name actual_version url digest <<< "$record"

    [[ "$actual_name" == "$name" ]] || fail "wrong source name for $name"
    [[ "$actual_version" == "$expected_version" ]] || fail "wrong version for $name"
    [[ "$url" == https://* ]] || fail "source URL must use HTTPS for $name"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 for $name"
}

test_digest_rejects_changed_input() {
    local fixture_dir fixture expected stderr_file
    fixture_dir="$(mktemp -d)"
    trap 'rm -rf "$fixture_dir"' RETURN
    fixture="$fixture_dir/archive"
    stderr_file="$fixture_dir/stderr"

    printf 'localagent-native-source-fixture\n' > "$fixture"
    expected="$(/usr/bin/shasum -a 256 "$fixture" | /usr/bin/awk '{print $1}')"
    verify_sha256 "$fixture" "$expected"

    printf 'changed\n' >> "$fixture"
    if verify_sha256 "$fixture" "$expected" 2> "$stderr_file"; then
        fail "changed archive passed digest verification"
    fi
    /usr/bin/grep -q "native.source_digest_mismatch" "$stderr_file" \
        || fail "digest mismatch did not return the stable error code"
}

test_download_replaces_invalid_cache() {
    local fixture_dir source destination lock_file digest
    fixture_dir="$(mktemp -d)"
    trap 'rm -rf "$fixture_dir"' RETURN
    source="$fixture_dir/source"
    destination="$fixture_dir/destination"
    lock_file="$fixture_dir/sources.lock"

    printf 'locked-source\n' > "$source"
    printf 'incomplete\n' > "$destination"
    digest="$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')"
    printf 'fixture|1|file://%s|%s\n' "$source" "$digest" > "$lock_file"

    download_locked_source fixture "$lock_file" "$destination"
    verify_sha256 "$destination" "$digest"
    [[ ! -e "$destination.partial" ]] || fail "partial download was not removed"
}

assert_lock_record alpine-minirootfs 3.21.0-aarch64
assert_lock_record lame 3.100
assert_lock_record ffmpeg 6.1.2
assert_lock_record llama-cpp 5d44db60089b0381cdbf7c45ce9ded43fc0c7f4c
test_digest_rejects_changed_input
test_download_replaces_invalid_cache

if [[ "${1:-}" == "--lock-only" ]]; then
    echo "native lock contract passed"
    exit 0
fi

platform="${LOCALAGENT_NATIVE_PLATFORM:-iphonesimulator}"
case "$platform" in
    iphoneos|iphonesimulator) ;;
    *) fail "unsupported platform $platform" ;;
esac

artifact_root="$NATIVE_ROOT/.build/$platform"
[[ -f "$artifact_root/lame/lib/libmp3lame.a" ]] \
    || fail "missing $platform LAME library"
[[ -d "$artifact_root/frameworks/FFmpeg.framework" ]] \
    || fail "missing $platform FFmpeg framework"
[[ -f "$artifact_root/libs/libish.a" ]] \
    || fail "missing $platform iSH library"
[[ -d "$artifact_root/resources/RootfsPatch.bundle" ]] \
    || fail "missing $platform RootfsPatch.bundle"

ROOTFS_ZIP="$NATIVE_ROOT/.build/resources/alpine-rootfs.zip"
[[ -f "$ROOTFS_ZIP" ]] || fail "missing Alpine rootfs bundle resource"
[[ -d "$NATIVE_ROOT/.build/resources/RootfsPatch.bundle" ]] \
    || fail "missing shared RootfsPatch.bundle resource"
[[ -f "$LOCALAGENT_ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework/Info.plist" ]] \
    || fail "missing LocalAgentInferenceNative.xcframework"
rootfs_listing="$(/usr/bin/unzip -l "$ROOTFS_ZIP")"
/usr/bin/grep -Eq 'alpine-rootfs/(data/|meta\.db)' <<< "$rootfs_listing" \
    || fail "rootfs zip does not contain fakefs data and metadata"

echo "native build contract passed"
