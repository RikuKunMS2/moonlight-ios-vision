#!/bin/bash
# Build the FFmpeg static libraries for visionOS (device and simulator)
# and package them as XCFrameworks in libs/FFmpeg/xcframeworks.
#
# Uses the same FFmpeg commit and the same minimal configuration as
# https://github.com/cgutman/moonlight-mobile-deps (FFmpeg.sh), which built
# the iOS and tvOS libraries in libs/FFmpeg/lib, so the headers in
# libs/FFmpeg/include (including the internal CBS/AV1 headers the app uses)
# match these libraries exactly.
#
# Requirements: Xcode with the visionOS SDKs, curl, make. No other tools.
# Usage (from the repository root): BuildScripts/build-ffmpeg-visionos.sh

set -euo pipefail

FFMPEG_COMMIT=3f890fbfd9014843c51408c8f7ab3ba4aef7d354
FFMPEG_SHA256=4e30c1ffa93b7bfe329032877d969d4811a5ac4c872125d334262f5158048899
XROS_MIN=2.0
LIBS="libavcodec libavformat libavutil"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/ffmpeg-visionos"
OUT="$ROOT/libs/FFmpeg/xcframeworks"
SRC="$WORK/FFmpeg-$FFMPEG_COMMIT"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK"
TARBALL="$WORK/ffmpeg-$FFMPEG_COMMIT.tar.gz"
if [ ! -f "$TARBALL" ]; then
    curl -fsSL -o "$TARBALL" "https://github.com/FFmpeg/FFmpeg/archive/$FFMPEG_COMMIT.tar.gz"
fi
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c -

# $1 SDK (xros / xrsimulator), $2 clang target triple
build_slice() {
    local sdk="$1" target="$2"
    local sysroot prefix tree
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    prefix="$WORK/install-$sdk"
    tree="$WORK/src-$sdk"

    rm -rf "$tree" "$prefix"
    mkdir -p "$tree"
    tar xzf "$TARBALL" -C "$tree" --strip-components 1

    (
        cd "$tree"
        ./configure --prefix="$prefix" \
            --cc="$(xcrun --sdk "$sdk" --find clang)" \
            --extra-cflags="-target $target -isysroot $sysroot" \
            --extra-ldflags="-target $target -isysroot $sysroot" \
            --arch=arm64 --target-os=darwin \
            --enable-cross-compile --disable-all --disable-autodetect --disable-x86asm \
            --enable-avcodec --enable-avformat --enable-muxer=flv --enable-decoder=av1
        make -j"$JOBS"
        make install
    )
}

build_slice xros "arm64-apple-xros$XROS_MIN"
build_slice xrsimulator "arm64-apple-xros$XROS_MIN-simulator"

rm -rf "$OUT"
mkdir -p "$OUT"
for lib in $LIBS; do
    xcodebuild -create-xcframework \
        -library "$WORK/install-xros/lib/$lib.a" \
        -library "$WORK/install-xrsimulator/lib/$lib.a" \
        -output "$OUT/$lib.xcframework"
done

# FFmpeg is configured without --enable-gpl or --enable-nonfree, so these
# libraries are LGPL 2.1 or later. Ship the licence and the source reference
# next to them.
cp "$WORK/src-xros/LICENSE.md" "$WORK/src-xros/COPYING.LGPLv2.1" "$OUT/"
cat > "$OUT/SOURCE.txt" <<SOURCE
FFmpeg static libraries for visionOS (device and simulator).

Source:   https://github.com/FFmpeg/FFmpeg/archive/$FFMPEG_COMMIT.tar.gz
SHA-256:  $FFMPEG_SHA256
Commit:   $FFMPEG_COMMIT (libavcodec 60.32.102)
Licence:  $(sed -n 's/^#define FFMPEG_LICENSE "\(.*\)"$/\1/p' "$WORK/src-xros/config.h")
Built by: BuildScripts/build-ffmpeg-visionos.sh
SOURCE

echo "Built $OUT from FFmpeg $FFMPEG_COMMIT"
