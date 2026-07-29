#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# LAME 3.100 Build Script for iOS arm64
# ============================================================================
# Cross-compiles LAME as a static library for use with FFmpeg's libmp3lame
# encoder on iOS.
#
# Usage:
#   OPENMINIS_PLATFORM=iphonesimulator ./build_lame.sh
#   ./build_lame.sh [clean]  # iphoneos by default
#
# Output:
#   deps/platforms/<platform>/lame/lib/libmp3lame.a
#   deps/platforms/<platform>/lame/include/lame/lame.h
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/native_platform.sh"
source "$SCRIPT_DIR/common.sh"
IFS='|' read -r LAME_LOCKED_NAME LAME_VERSION LAME_URL LAME_DIGEST \
    <<< "$(native_source_record lame "$LOCALAGENT_NATIVE_LOCK")"
LAME_TARBALL="lame-${LAME_VERSION}.tar.gz"
LAME_ARCHIVE="$LOCALAGENT_NATIVE_DOWNLOAD_ROOT/$LAME_TARBALL"
LAME_SRC_DIR="$LOCALAGENT_NATIVE_SOURCE_ROOT/lame-${LAME_VERSION}"
LAME_BUILD_DIR="$OPENMINIS_NATIVE_BUILD_ROOT/lame"
LAME_INSTALL_DIR="$OPENMINIS_NATIVE_ARTIFACT_ROOT/lame"

IOS_DEPLOYMENT_TARGET="14.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_error()   { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ============================================================================
# Clean
# ============================================================================
if [ "${1:-}" == "clean" ]; then
    log_info "Cleaning LAME $OPENMINIS_PLATFORM build artifacts..."
    rm -rf "$LAME_BUILD_DIR" "$LAME_INSTALL_DIR"
    log_success "Clean completed"
    exit 0
fi

# ============================================================================
# Download source
# ============================================================================
download_locked_source lame "$LOCALAGENT_NATIVE_LOCK" "$LAME_ARCHIVE"
if [ ! -d "$LAME_SRC_DIR" ]; then
    log_info "Extracting locked LAME ${LAME_VERSION} source..."
    mkdir -p "$LOCALAGENT_NATIVE_SOURCE_ROOT"
    tar xzf "$LAME_ARCHIVE" -C "$LOCALAGENT_NATIVE_SOURCE_ROOT"
    log_success "LAME source extracted"
else
    log_info "LAME source already present, skipping extraction"
fi

# ============================================================================
# Cross-compile for iOS arm64
# ============================================================================
log_info "Configuring LAME for $OPENMINIS_PLATFORM arm64..."

IOS_SDK=$(xcrun --sdk "$OPENMINIS_PLATFORM" --show-sdk-path)
CC="$(xcrun --sdk "$OPENMINIS_PLATFORM" -f clang)"

export CC
export CFLAGS="-arch arm64 $OPENMINIS_MIN_VERSION_FLAG -isysroot $IOS_SDK -Oz -fPIC -Wno-implicit-function-declaration"
export LDFLAGS="-arch arm64 $OPENMINIS_MIN_VERSION_FLAG -isysroot $IOS_SDK"

if [ -f "$LAME_SRC_DIR/config.status" ]; then
    log_info "Cleaning legacy in-source LAME build..."
    make -C "$LAME_SRC_DIR" distclean
fi

mkdir -p "$LAME_BUILD_DIR"
cd "$LAME_BUILD_DIR"

if [ ! -f "$LAME_BUILD_DIR/Makefile" ]; then
    "$LAME_SRC_DIR/configure" \
        --prefix="$LAME_INSTALL_DIR" \
        --host=aarch64-apple-darwin \
        --disable-shared \
        --enable-static \
        --disable-frontend \
        --disable-decoder \
        --disable-gtktest \
        --with-pic
fi

log_info "Building LAME..."
make -j"$(native_job_count)"
make install

# ============================================================================
# Verify
# ============================================================================
if [ -f "$LAME_INSTALL_DIR/lib/libmp3lame.a" ]; then
    log_success "LAME ${LAME_VERSION} built successfully"
    echo ""
    echo "  Static library: $LAME_INSTALL_DIR/lib/libmp3lame.a"
    echo "  Headers:        $LAME_INSTALL_DIR/include/lame/lame.h"
    echo ""
    file "$LAME_INSTALL_DIR/lib/libmp3lame.a"
else
    log_error "Build failed — libmp3lame.a not found"
fi
