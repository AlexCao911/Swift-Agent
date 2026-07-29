#!/usr/bin/env bash
set -euo pipefail

LOCALAGENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE_ROOT="$LOCALAGENT_ROOT/ThirdParty/OpenMinisNative"
SCRIPT_ROOT="$LOCALAGENT_ROOT/scripts/native"

usage() {
    echo "Usage: $0 --platform iphoneos|iphonesimulator" >&2
}

platform=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform)
            platform="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case "$platform" in
    iphoneos|iphonesimulator) ;;
    *)
        usage
        exit 2
        ;;
esac

export LOCALAGENT_NATIVE_PLATFORM="$platform"

"$SCRIPT_ROOT/build_lame.sh"
"$SCRIPT_ROOT/build_ffmpeg.sh"
"$SCRIPT_ROOT/build_ish.sh"
"$SCRIPT_ROOT/prepare_alpine_rootfs.sh"

artifact_root="$NATIVE_ROOT/.build/$platform"
rootfs_zip="$NATIVE_ROOT/.build/resources/alpine-rootfs.zip"
shared_rootfs_patch="$NATIVE_ROOT/.build/resources/RootfsPatch.bundle"
inference_xcframework="$LOCALAGENT_ROOT/toolkit/Artifacts/LocalAgentInferenceNative.xcframework"

rm -rf "$shared_rootfs_patch"
/usr/bin/ditto "$artifact_root/resources/RootfsPatch.bundle" "$shared_rootfs_patch"

test -f "$artifact_root/lame/lib/libmp3lame.a"
test -d "$artifact_root/frameworks/FFmpeg.framework"
test -f "$artifact_root/libs/libish.a"
test -d "$artifact_root/resources/RootfsPatch.bundle"
test -f "$rootfs_zip"
test -d "$shared_rootfs_patch"
rootfs_listing="$(/usr/bin/unzip -l "$rootfs_zip")"
/usr/bin/grep -Eq 'alpine-rootfs/(data/|meta\.db)' <<< "$rootfs_listing"

verify_macho_platform() {
    local binary="$1"
    local expected="$2"
    local build_info
    build_info="$(/usr/bin/xcrun vtool -show-build "$binary" 2>/dev/null)"

    if [[ "$expected" == "iphoneos" ]]; then
        echo "$build_info" | /usr/bin/grep -Eq 'platform IOS$'
        ! echo "$build_info" | /usr/bin/grep -Eq 'platform IOSSIMULATOR$'
    else
        echo "$build_info" | /usr/bin/grep -Eq 'platform IOSSIMULATOR$'
    fi
}

verify_archive_platform() {
    local archive="$1"
    local expected="$2"
    local scratch member
    scratch="$(mktemp -d)"
    member="$(/usr/bin/ar -t "$archive" | /usr/bin/grep -E '\.o$' | /usr/bin/sed -n '1p')"
    test -n "$member"
    (
        cd "$scratch"
        /usr/bin/ar -x "$archive" "$member"
        verify_macho_platform "$scratch/$member" "$expected"
    )
    rm -rf "$scratch"
}

verify_archive_platform "$artifact_root/lame/lib/libmp3lame.a" "$platform"
verify_archive_platform "$artifact_root/libs/libish.a" "$platform"
verify_macho_platform "$artifact_root/frameworks/FFmpeg.framework/FFmpeg" "$platform"

if [[ ! -f "$inference_xcframework/Info.plist" ]]; then
    "$LOCALAGENT_ROOT/scripts/build-local-agent-inference-xcframework.sh"
fi
test -f "$inference_xcframework/Info.plist"

echo "LocalAgent native preparation completed for $platform"
