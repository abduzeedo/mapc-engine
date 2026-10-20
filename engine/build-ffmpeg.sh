#!/usr/bin/env bash
# Builds the FFmpeg libraries MaPC's engines ship for Wine's video playback (Media Foundation via winedmo).
#   engine/build-ffmpeg.sh <prefix>     -> <prefix>/lib/libav{util,format,codec}.*.dylib + headers
# LGPL-2.1 only: no --enable-gpl / --enable-nonfree / --enable-version3, no external libraries.
# Decoders: only the patent-cleared list in ffmpeg-decoders.txt (Fedora's). The full set comes from the user's
# own Homebrew ffmpeg@7, never from MaPC (see the app's Video Support setting).
set -euo pipefail
cd "$(dirname "$0")"
PREFIX="$(mkdir -p "$1" && cd "$1" && pwd)"
CACHE="${CACHE_DIR:-.cache/dl}"; mkdir -p "$CACHE"; CACHE="$(cd "$CACHE" && pwd)"
FF_NAME="ffmpeg-7.1.5.tar.xz"
FF_URL="https://ffmpeg.org/releases/$FF_NAME"
FF_SHA="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"   # = Homebrew ffmpeg@7's pin
[ -f "$CACHE/$FF_NAME" ] || curl -fL -sS -o "$CACHE/$FF_NAME" "$FF_URL"
[ "$(shasum -a 256 "$CACHE/$FF_NAME" | cut -d' ' -f1)" = "$FF_SHA" ] || { echo "checksum mismatch: $FF_NAME" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar -xJf "$CACHE/$FF_NAME" -C "$WORK" --strip-components=1
DECODERS="$(grep -v '^#' ffmpeg-decoders.txt | paste -sd, -)"
( cd "$WORK" && /usr/bin/env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" MACOSX_DEPLOYMENT_TARGET=14.0 \
  ./configure --prefix="$PREFIX" --enable-cross-compile --target-os=darwin --arch=x86_64 \
    --cc="clang -arch x86_64" --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-mmacosx-version-min=14.0" \
    --install-name-dir='@rpath' --enable-shared --disable-static --disable-programs --disable-doc \
    --disable-autodetect --disable-network --disable-x86asm \
    --disable-everything --disable-avdevice --disable-avfilter --disable-postproc --disable-swscale --disable-swresample \
    --enable-decoder="$DECODERS" --enable-demuxers --enable-parsers --enable-bsfs --enable-protocol=file \
    > "$WORK/configure.out" 2>&1 ) || { tail -20 "$WORK/configure.out" >&2; exit 1; }
grep -q 'License: LGPL version 2.1 or later' "$WORK/ffbuild/config.log" 2>/dev/null || grep -q 'LGPL version 2.1 or later' "$WORK/configure.out" \
  || { echo "FFmpeg isn't configured LGPL-2.1+" >&2; exit 1; }
( cd "$WORK" && make -j"$(sysctl -n hw.ncpu)" > make.out 2>&1 && make install > install.out 2>&1 ) \
  || { tail -30 "$WORK/make.out" >&2; exit 1; }
for d in H264 HEVC VC1 WMV3 WMAPRO; do
  grep -q "^#define CONFIG_${d}_DECODER 1" "$WORK/config_components.h" && { echo "$d decoder enabled" >&2; exit 1; }
done
echo "FFmpeg 7.1.5 (LGPL, patent-cleared decoders) in $PREFIX"
