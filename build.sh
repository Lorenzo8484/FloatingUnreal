#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# build.sh — FloatingUnreal
# Installa Theos in workspace/.theos (persistente tra i restart).
# Uso: bash build.sh
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

WDIR="$(cd "$(dirname "$0")" && pwd)"
THEOS_DIR="$WDIR/.theos"
SDK_TAG="master-146e41f"
SDK_NAME="iPhoneOS16.5.sdk"
SDK_URL="https://github.com/theos/sdks/releases/download/${SDK_TAG}/${SDK_NAME}.tar.xz"
SRC_DIR="$WDIR/tweak-menu"
BUILD_DIR="$WDIR/.theos-build"

CLANG=/nix/store/x6rsdc4s0f1j9bn1cx2h1l5fj8765ykw-clang-19.1.7/bin/clang
LLD=/nix/store/a8zn2v3wyi393iahnjddnsgh05idj7y3-lld-19.1.7/bin/ld64.lld
LDID=/nix/store/2mq8dg7hgq1rp0bhdm59l4jl71w5pw30-ldid-2.1.5/bin/ldid
RESDIR=/nix/store/4bb195ym905lzvwnbm86nxz2j625hrv4-clang-wrapper-19.1.7/resource-root
GNU_AR=/nix/store/4bb195ym905lzvwnbm86nxz2j625hrv4-clang-wrapper-19.1.7/bin/ar

echo "╔══════════════════════════════════════════╗"
echo "║         FloatingUnreal  build.sh         ║"
echo "╚══════════════════════════════════════════╝"

if [ ! -f "$THEOS_DIR/makefiles/common.mk" ]; then
    echo "▶ Theos non trovato — installo..."
    git clone --depth=1 https://github.com/theos/theos.git "$THEOS_DIR" 2>&1 | tail -3
fi

SDK_PATH="$THEOS_DIR/sdks/$SDK_NAME"
if [ ! -d "$SDK_PATH" ]; then
    echo "▶ Scarico SDK $SDK_NAME ..."
    mkdir -p "$THEOS_DIR/sdks"
    curl -fsSL "$SDK_URL" | tar -xJC "$THEOS_DIR/sdks/"
fi

mkdir -p "$THEOS_DIR/vendor/include" "$THEOS_DIR/vendor/lib"
touch "$THEOS_DIR/vendor/include/.git" "$THEOS_DIR/vendor/lib/.git"

TCDIR="$THEOS_DIR/toolchain/linux/iphone/bin"
mkdir -p "$TCDIR"
for tool in clang clang++; do ln -sf "$CLANG" "$TCDIR/$tool"; done
for tool in ar ranlib; do ln -sf "$GNU_AR" "$TCDIR/$tool"; done

WRAPPER="$TCDIR/ld64.lld"
cat > "$WRAPPER" << WEOF
#!/bin/bash
args=(); skip=0; nextIsMinVer=0
for a in "\$@"; do
  if [ \$skip -eq 1 ]; then skip=0; continue; fi
  if [ \$nextIsMinVer -eq 1 ]; then
    args+=("-platform_version" "ios" "\$a" "16.5")
    nextIsMinVer=0; continue
  fi
  case "\$a" in
    -iphoneos_version_min) nextIsMinVer=1 ;;
    -dynamic_lookup) ;;
    -multiply_defined) skip=1 ;;
    -lroot_oldabi) ;;
    *) args+=("\$a") ;;
  esac
done
exec ${LLD} "\${args[@]}"
WEOF
chmod +x "$WRAPPER"

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
cp "$SRC_DIR/"*.mm "$BUILD_DIR/" 2>/dev/null || true
cp "$SRC_DIR/"*.h  "$BUILD_DIR/" 2>/dev/null || true
cp "$SRC_DIR/Makefile" "$BUILD_DIR/"
[ -f "$SRC_DIR/Tweak.xm" ] && cp "$SRC_DIR/Tweak.xm" "$BUILD_DIR/Tweak.mm"

echo "▶ Compilazione ..."
cd "$BUILD_DIR"
export THEOS="$THEOS_DIR"
export PATH="$TCDIR:$PATH"

make all FINALPACKAGE=1 \
  CFLAGS="-resource-dir $RESDIR -Wno-deprecated-module-dot-map" \
  CXXFLAGS="-resource-dir $RESDIR -Wno-deprecated-module-dot-map" \
  LDFLAGS="-fuse-ld=$WRAPPER" 2>&1

DYLIB=$(find "$BUILD_DIR/.theos/obj" -name "*.dylib" 2>/dev/null | head -1)
[ -z "$DYLIB" ] && echo "❌ Dylib non trovata" && exit 1
[ -x "$LDID" ] && "$LDID" -S "$DYLIB"
cp "$DYLIB" "$WDIR/FloatingUnreal.dylib"
tar czf FloatingUnreal_dylib.tar.gz FloatingUnreal.dylib
echo "✅ Build completato! Output: $WDIR/FloatingUnreal_dylib.tar.gz"
