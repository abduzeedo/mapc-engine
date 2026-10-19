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
# The native (not "-builtin") repack: the same build without Wine's builtin marker, byte for byte otherwise.
# It goes next to Wine (lib/dxvk), not over Wine's own d3d11/d3d10core, so WineD3D stays Wine's.
DXVK_NAME="dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz"
DXVK_URL="https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/$DXVK_NAME"
DXVK_SHA="acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477"

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
tar -xzf "$CACHE/$DXVK_NAME" -C "$WORK"
DX="$(ls -d "$WORK"/dxvk-macOS*/ | head -1)"
# Copied into each environment as native DLLs at launch (NativeBackendDLLs); Wine's builtins stay untouched.
mkdir -p "$LIB/../dxvk/x86_64-windows" "$LIB/../dxvk/i386-windows"
cp "$DX"/x64/*.dll "$LIB/../dxvk/x86_64-windows/"; cp "$DX"/x32/*.dll "$LIB/../dxvk/i386-windows/"
cp "$WRAPPER" "$ENG/steamwebhelper-wrapper.exe"
# License texts and notices for everything in the engine (licenses/), plus how this build was made.
mkdir -p "$ENG/licenses/build"
cp licenses/* "$ENG/licenses/"
cp build-engine.sh manifest-add.py steamwebhelper-wrapper/wrapper.c "$ENG/licenses/build/"
cat > "$ENG/ENGINE.json" <<JSON
{ "version": "$VERSION", "wineVersion": "11.18 (Staging)", "backends": ["dxvk"], "minMacOS": "15.0" }
JSON
cat > "$ENG/licenses/NOTICE.txt" <<'TXT'
MaPC engine. Third-party software and licenses: THIRD-PARTY-NOTICES.md (this folder).
Wine Staging (LGPL-2.1+): https://www.winehq.org  - build: https://github.com/Gcenx/macOS_Wine_builds
DXVK (zlib), macOS fork: https://github.com/Gcenx/DXVK-macOS
No Apple software is included. Source offer: support@mapc.games, for at least three years.
TXT

ARCHIVE="$OUT/macade-engine-$VERSION.tar.xz"
rm -f "$ARCHIVE"
XZ_OPT="-T0 -6" tar -cJf "$ARCHIVE" -C "$ENG" .
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"; SIZE="$(stat -f%z "$ARCHIVE")"
BASE="${MANIFEST_BASE_URL:-file://$OUT}"
./manifest-add.py "$OUT/engine-manifest.json" "$VERSION" "$BASE/macade-engine-$VERSION.tar.xz" "$SHA" "$SIZE" dxvk
echo "engine:   $ARCHIVE ($((SIZE / 1048576)) MB)"; echo "sha256:   $SHA"; echo "manifest: $OUT/engine-manifest.json"
