#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# build_here.sh — Compila FloatingUnreal su WSL/Ubuntu
# Prerequisiti: clang-19, lld-19, SDK iOS 16.5
# Uso: bash build_here.sh [VERSION=1.0.63]
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

VER="${1:-1.0.63}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCDIR="$SCRIPT_DIR/backup/v2.0"
SDK="/home/alina/sdk/iPhoneOS16.5.sdk"
CLANG="/usr/bin/clang-19"
LLD64="/usr/bin/ld64.lld-19"
BUILD="/tmp/afloat_build_$$"

DYLIB="AFloatingUnreal_v${VER}.dylib"
TARBALL="AFloatingUnreal_v${VER}.tar.gz"

# ── Scarica SDK se mancante ───────────────────────────────────────
if [ ! -d "$SDK" ]; then
    echo "▶ Download iOS SDK..."
    mkdir -p "$(dirname "$SDK")"
    curl -fsSL --retry 3 \
      "https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz" \
      | tar -xJC "$(dirname "$SDK")"
fi

rm -rf "$BUILD"; mkdir -p "$BUILD"

BASE_FLAGS="-target arm64-apple-ios14.0 -isysroot $SDK \
  -fobjc-arc -fmodules -fvisibility=hidden \
  -I$SRCDIR -x objective-c++ \
  -Wno-deprecated-module-dot-map -c"

echo "=== FloatingUnreal v${VER} ==="

for f in Tweak.mm FloatingMenu.mm ShaderPage.mm; do
    echo "  Compiling $f ..."
    $CLANG $BASE_FLAGS "$SRCDIR/$f" -o "$BUILD/${f%.mm}.o"
done

echo "  Linking $DYLIB ..."
$LLD64 -demangle -dynamic -dylib \
  -arch arm64 \
  -platform_version ios 14.0 16.5 \
  -syslibroot "$SDK" \
  -lobjc -lc++ -lc \
  -framework Foundation -framework UIKit -framework Metal \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$DYLIB" \
  "$BUILD/Tweak.o" "$BUILD/FloatingMenu.o" "$BUILD/ShaderPage.o" \
  -o "$SCRIPT_DIR/$DYLIB"

# Firma (opzionale, salta se ldid non presente)
if command -v ldid &>/dev/null; then
    ldid -S "$SCRIPT_DIR/$DYLIB" && echo "  Firmato con ldid ✓"
fi

# Package
cd /tmp
cp "$SCRIPT_DIR/$DYLIB" "$DYLIB"
tar czf "$SCRIPT_DIR/$TARBALL" "$DYLIB"
rm "$DYLIB"

rm -rf "$BUILD"

echo "╔══════════════════════════════════════════╗"
echo "║  ✅ BUILD COMPLETATO                     ║"
echo "╠══════════════════════════════════════════╣"
ls -lh "$SCRIPT_DIR/$DYLIB" "$SCRIPT_DIR/$TARBALL"
echo "╚══════════════════════════════════════════╝"
