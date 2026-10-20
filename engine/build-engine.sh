#!/usr/bin/env bash
# Assembles a Macade engine tarball + manifest from pinned upstream releases (plan §4.2).
#   engine/build-engine.sh [version]             -> $OUT_DIR/macade-engine-<version>.tar.xz (+ manifest entry)
# Env: CACHE_DIR (downloads, default engine/.cache/dl)  OUT_DIR (default engine/dist)
#      MANIFEST_BASE_URL (default: file:// into OUT_DIR)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-1.0.0}"
CACHE="${CACHE_DIR:-.cache/dl}"; OUT="${OUT_DIR:-dist}"; WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE" "$OUT"
CACHE="$(cd "$CACHE" && pwd)"; OUT="$(cd "$OUT" && pwd)"

# Pinned inputs. Re-verify fast-moving versions before bumping (plan §12.2).
WINE_NAME="wine-staging-11.18-osx64.tar.xz"
WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/$WINE_NAME"
WINE_SHA="b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127"
# DXVK_LAYOUT=builtin (default): the "-builtin" repack replaces Wine's d3d11/d3d10core, as in engine 1.0.0.
# DXVK_LAYOUT=native: the native repack (same build without Wine's builtin marker) goes next to Wine (lib/dxvk)
#   and NativeBackendDLLs copies it into each environment at launch, so WineD3D stays Wine's. Not released yet:
#   with it, Cuphead hangs when it quits (it doesn't with the builtin layout).
DXVK_LAYOUT="${DXVK_LAYOUT:-builtin}"
DXVK_URL_BASE="https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack"
case "$DXVK_LAYOUT" in
  builtin) DXVK_NAME="dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"
           DXVK_SHA="810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00" ;;
  native)  DXVK_NAME="dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz"
           DXVK_SHA="acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477" ;;
  *) echo "DXVK_LAYOUT must be builtin or native" >&2; exit 1 ;;
esac
DXVK_URL="$DXVK_URL_BASE/$DXVK_NAME"

fetch() { # name url sha
  local f="$CACHE/$1"
  [ -f "$f" ] || curl -fL -sS -o "$f" "$2"
  if [ -n "${3:-}" ]; then
    [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch: $1" >&2; exit 1; }
  fi
}
fetch "$WINE_NAME" "$WINE_URL" "$WINE_SHA"
fetch "$DXVK_NAME" "$DXVK_URL" "$DXVK_SHA"

# Steam web helper wrapper (software rendering, spike finding). Build it when mingw is present.
WRAPPER="$WORK/steamwebhelper-wrapper.exe"
if command -v x86_64-w64-mingw32-gcc >/dev/null; then
  x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static -o "$WRAPPER" steamwebhelper-wrapper/wrapper.c
elif [ -f "$CACHE/steamwebhelper-wrapper.exe" ]; then cp "$CACHE/steamwebhelper-wrapper.exe" "$WRAPPER"
else echo "need mingw-w64 (brew install mingw-w64) to build the wrapper" >&2; exit 1; fi

ENG="$WORK/engine"; mkdir -p "$ENG"
tar -xJf "$CACHE/$WINE_NAME" -C "$ENG"
APP="$(ls -d "$ENG"/*.app | head -1)"; LIB="$APP/Contents/Resources/wine/lib/wine"
# Gcenx bundles Wine Gecko (Firefox's engine, for Wine's mshtml). MaPC always disables mshtml, so it's never used:
# leave it out rather than ship it. Wine Mono stays: .NET programs use it (licenses in licenses/wine-mono/).
rm -rf "$APP/Contents/Resources/wine/share/wine/gecko"
[ -d "$APP/Contents/Resources/wine/share/wine/mono/wine-mono-11.3.0" ] \
  || { echo "expected Wine Mono 11.3.0 in the Wine build (update licenses-wine-mono-*)" >&2; exit 1; }
tar -xzf "$CACHE/$DXVK_NAME" -C "$WORK"
DX="$(ls -d "$WORK"/dxvk-macOS*/ | head -1)"
if [ "$DXVK_LAYOUT" = builtin ]; then
  cp "$DX"/x86_64-windows/*.dll "$LIB/x86_64-windows/"; cp "$DX"/i386-windows/*.dll "$LIB/i386-windows/"
else
  # Copied into each environment as native DLLs at launch (NativeBackendDLLs); Wine's builtins stay untouched.
  mkdir -p "$LIB/../dxvk/x86_64-windows" "$LIB/../dxvk/i386-windows"
  cp "$DX"/x64/*.dll "$LIB/../dxvk/x86_64-windows/"; cp "$DX"/x32/*.dll "$LIB/../dxvk/i386-windows/"
fi
cp "$WRAPPER" "$ENG/steamwebhelper-wrapper.exe"
# License texts and notices for everything in the engine (licenses/), plus how this build was made.
mkdir -p "$ENG/licenses/build"
cp licenses/* "$ENG/licenses/"
# Libraries Wine builds into its own DLLs (libs/ in Wine's source), from upstream Wine 11.18.
mkdir -p "$ENG/licenses/wine-libs"; cp licenses-wine-11.18-libs/* "$ENG/licenses/wine-libs/"
mkdir -p "$ENG/licenses/wine-mono"; cp licenses-wine-mono-11.3.0/* "$ENG/licenses/wine-mono/"
cp build-engine.sh manifest-add.py steamwebhelper-wrapper/wrapper.c "$ENG/licenses/build/"
cat > "$ENG/ENGINE.json" <<JSON
{ "version": "$VERSION", "wineVersion": "11.18 (Staging)", "backends": ["dxvk"], "minMacOS": "15.0" }
JSON
cat > "$ENG/licenses/NOTICE.txt" <<TXT
MaPC engine $VERSION. Third-party software and licenses: THIRD-PARTY-NOTICES.md (this folder).
Wine Staging 11.18 (LGPL-2.1+): https://www.winehq.org  - build: https://github.com/Gcenx/macOS_Wine_builds
Wine Mono 11.3.0 (MIT, LGPL, GPL with exception, MS-PL, zlib; see wine-mono/): https://gitlab.winehq.org/mono/wine-mono
DXVK (zlib), macOS fork: https://github.com/Gcenx/DXVK-macOS
Source: published with this engine at https://github.com/abduzeedo/mapc-site/releases/tag/engine-$VERSION
No Apple software is included. Source offer: support@mapc.games, for at least three years.
TXT

ARCHIVE="$OUT/macade-engine-$VERSION.tar.xz"
rm -f "$ARCHIVE"
XZ_OPT="-T0 -6" tar -cJf "$ARCHIVE" -C "$ENG" .
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"; SIZE="$(stat -f%z "$ARCHIVE")"
BASE="${MANIFEST_BASE_URL:-file://$OUT}"
./manifest-add.py "$OUT/engine-manifest.json" "$VERSION" "$BASE/macade-engine-$VERSION.tar.xz" "$SHA" "$SIZE" dxvk
echo "engine:   $ARCHIVE ($((SIZE / 1048576)) MB)"; echo "sha256:   $SHA"; echo "manifest: $OUT/engine-manifest.json"
