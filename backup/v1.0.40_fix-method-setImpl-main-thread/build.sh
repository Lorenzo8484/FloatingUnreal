#!/usr/bin/env bash
# build.sh — AFloatingUnreal direct clang build
# Uso: bash build.sh
set -euo pipefail

SRCDIR="$(cd "$(dirname "$0")" && pwd)"
VER=$(grep '^Version:' "$SRCDIR/control" | awk '{print $2}')
DYLIB="AFloatingUnreal_v${VER}.dylib"
TARBALL="AFloatingUnreal_v${VER}.tar.gz"

CLANG=/nix/store/x6rsdc4s0f1j9bn1cx2h1l5fj8765ykw-clang-19.1.7/bin/clang
LLD=/nix/store/a8zn2v3wyi393iahnjddnsgh05idj7y3-lld-19.1.7/bin/ld64.lld
LDID=/nix/store/2mq8dg7hgq1rp0bhdm59l4jl71w5pw30-ldid-2.1.5/bin/ldid
RESDIR=/nix/store/4bb195ym905lzvwnbm86nxz2j625hrv4-clang-wrapper-19.1.7/resource-root

SDK=/tmp/sdk/iPhoneOS16.5.sdk
SDK_URL="https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz"

echo "=== AFloatingUnreal v${VER} build ==="

# Download SDK if missing (/tmp is ephemeral)
if [ ! -d "$SDK" ]; then
    echo "Downloading iOS SDK..."
    mkdir -p /tmp/sdk
    curl -fsSL --retry 3 "$SDK_URL" | tar -xJC /tmp/sdk/
fi

BUILDTMP=/tmp/afloat_build
rm -rf "$BUILDTMP"; mkdir -p "$BUILDTMP"

BASE_FLAGS="-resource-dir $RESDIR -target arm64-apple-ios14.0 -isysroot $SDK \
  -fobjc-arc -fmodules -fvisibility=hidden -I$SRCDIR \
  -DDYLIB_VERSION=\"$VER\" -O2 -g0 -x objective-c++ -Wno-deprecated-module-dot-map"

echo "Compiling Tweak.mm..."
$CLANG $BASE_FLAGS -c "$SRCDIR/Tweak.mm"       -o "$BUILDTMP/Tweak.o"

echo "Compiling FloatingMenu.mm..."
$CLANG $BASE_FLAGS -c "$SRCDIR/FloatingMenu.mm" -o "$BUILDTMP/FloatingMenu.o"

echo "Compiling ShaderPage.mm..."
$CLANG $BASE_FLAGS -c "$SRCDIR/ShaderPage.mm"   -o "$BUILDTMP/ShaderPage.o"

echo "Linking $DYLIB..."
$LLD -demangle -dynamic -dylib \
  -arch arm64 \
  -platform_version ios 14.0 16.5 \
  -syslibroot "$SDK" \
  -lobjc -lc++ -lc \
  -framework Foundation -framework UIKit -framework Metal \
  -rpath /usr/lib/swift \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$DYLIB" \
  "$BUILDTMP/Tweak.o" "$BUILDTMP/FloatingMenu.o" "$BUILDTMP/ShaderPage.o" \
  -o "$SRCDIR/$DYLIB"

$LDID -S "$SRCDIR/$DYLIB" && echo "ldid signed OK"

# Package — FLAT: solo la dylib, nessuna cartella
cd /tmp && cp "$SRCDIR/$DYLIB" "AFloatingUnreal_v${VER}.dylib"
tar czf "$SRCDIR/$TARBALL" "AFloatingUnreal_v${VER}.dylib"

echo "=== Done ==="
echo "  Dylib:   $SRCDIR/$DYLIB"
echo "  Package: $SRCDIR/$TARBALL"
