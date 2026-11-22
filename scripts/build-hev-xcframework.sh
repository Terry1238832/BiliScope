#!/bin/bash
# Rebuilds App/Vendor/HevSocks5Tunnel.xcframework from hev-socks5-tunnel's source.
#
# Built from source rather than taken from Tun2SocksKit: on 2026-11-22 the
# 5.20.0 release asset no longer matched the checksum in that tag's manifest.
# This follows upstream's build-apple.sh, limited to iPhone and its simulator.
#
# Usage: scripts/build-hev-xcframework.sh [tag]   (default 2.20.0)
set -euo pipefail

TAG="${1:-2.20.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/App/Vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --quiet --depth 1 --branch "$TAG" --recursive --shallow-submodules \
    https://github.com/heiher/hev-socks5-tunnel.git "$WORK/src"
SRC="$WORK/src"

build() {
    local sdk=$1 arch=$2
    make -C "$SRC" -s \
        PP="xcrun --sdk $sdk --toolchain $sdk clang" \
        CC="xcrun --sdk $sdk --toolchain $sdk clang" \
        CFLAGS="-arch $arch -m${sdk}-version-min=15.0" \
        LFLAGS="-arch $arch -m${sdk}-version-min=15.0 -Wl,-Bsymbolic-functions" static
    mkdir -p "$WORK/out/$sdk-$arch"
    libtool -static -o "$WORK/out/$sdk-$arch/libhev-socks5-tunnel.a" \
        "$SRC/bin/libhev-socks5-tunnel.a" \
        "$SRC/third-part/lwip/bin/liblwip.a" \
        "$SRC/third-part/yaml/bin/libyaml.a" \
        "$SRC/third-part/hev-task-system/bin/libhev-task-system.a"
    make -C "$SRC" -s clean
}

build iphoneos arm64
build iphonesimulator arm64

mkdir -p "$WORK/out/include/HevSocks5Tunnel"
cp "$SRC/src/hev-main.h" "$SRC/module.modulemap" "$WORK/out/include/HevSocks5Tunnel/"

rm -rf "$VENDOR/HevSocks5Tunnel.xcframework"
mkdir -p "$VENDOR"
xcodebuild -create-xcframework \
    -library "$WORK/out/iphoneos-arm64/libhev-socks5-tunnel.a" -headers "$WORK/out/include" \
    -library "$WORK/out/iphonesimulator-arm64/libhev-socks5-tunnel.a" -headers "$WORK/out/include" \
    -output "$VENDOR/HevSocks5Tunnel.xcframework"
git -C "$SRC" rev-parse HEAD > "$VENDOR/HevSocks5Tunnel.source-commit"
cp "$SRC/License" "$VENDOR/HevSocks5Tunnel.LICENSE"
echo "Built hev-socks5-tunnel $TAG ($(cat "$VENDOR/HevSocks5Tunnel.source-commit"))"
