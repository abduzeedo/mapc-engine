#!/usr/bin/env bash
# Builds Macade's DirectX 12 engine: Wine from CodeWeavers' CrossOver source, ready for Apple's D3DMetal.
#   engine/build-engine-d3dmetal.sh [version]        -> $OUT_DIR/macade-engine-<version>.tar.xz (+ manifest entry)
#
# Why CrossOver's Wine: D3DMetal needs hooks that only CodeWeavers' tree has (winemac's `macdrv_functions`,
# ntdll's `__wine_unix_call` export and its libd3dshared loader). Stock Wine, e.g. the 1.x engine, lacks them.
#
# Trust: every download is pinned by SHA-256. Wine is compiled here from CodeWeavers' published source;
# no third-party Wine binary is used.
#
# No Apple software is part of this build or of the engine it produces. If a user installs Apple's Game Porting
# Toolkit themselves, the MaPC app copies D3DMetal from that download (MacadeKit `D3DMetalStore`).
# Its x86_64 runtime libraries (FreeType, GnuTLS, SDL2, MoltenVK) are the ones the 1.x engine already ships.
#
# Env:
#   CACHE_DIR      downloads (default engine/.cache/dl)    WORK_DIR  build tree (default engine/.cache/cx)
#   OUT_DIR        default engine/dist                     MANIFEST_BASE_URL  default: file:// into OUT_DIR
#   RESUME=1       continue the existing build tree in WORK_DIR instead of reconfiguring from scratch
# Needs: Xcode, Rosetta, `brew install bison pkgconf freetype gnutls sdl2 mingw-w64`.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-2.0.0}"
CACHE="${CACHE_DIR:-.cache/dl}"; WORK="${WORK_DIR:-.cache/cx}"; OUT="${OUT_DIR:-dist}"
mkdir -p "$CACHE" "$WORK" "$OUT"
CACHE="$(cd "$CACHE" && pwd)"; WORK="$(cd "$WORK" && pwd)"; OUT="$(cd "$OUT" && pwd)"

CX_VERSION="26.3.0"
CX_NAME="crossover-sources-$CX_VERSION.tar.gz"
CX_URL="https://media.codeweavers.com/pub/crossover/source/$CX_NAME"
CX_SHA="ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
RUNTIME_NAME="wine-staging-11.18-osx64.tar.xz"        # same pin as build-engine.sh
RUNTIME_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/$RUNTIME_NAME"
RUNTIME_SHA="b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127"
# DXMT (Direct3D 10/11 on Metal; the only path for 32-bit D3D10/11 games). v0.80 is the last MIT release
# (later ones are LGPL). It needs winemac's `macdrv_functions` table, which CrossOver's Wine has (d3dmetal.c).
DXMT_NAME="dxmt-v0.80-builtin.tar.gz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/$DXMT_NAME"
DXMT_SHA="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "need mingw-w64 (brew install mingw-w64)" >&2; exit 1; }
BREW="$(brew --prefix)"
[ -x "$BREW/opt/bison/bin/bison" ] || { echo "need bison >= 3 (brew install bison)" >&2; exit 1; }

fetch() { # name url sha
  local f="$CACHE/$1"
  if [ ! -f "$f" ]; then curl -fL --retry 3 -sS -o "$f.part" "$2"; mv "$f.part" "$f"; fi
  [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$3" ] || { echo "checksum mismatch: $1 (moved aside)" >&2; mv "$f" "$f.bad"; exit 1; }
}
fetch "$CX_NAME" "$CX_URL" "$CX_SHA"
fetch "$RUNTIME_NAME" "$RUNTIME_URL" "$RUNTIME_SHA"
fetch "$DXMT_NAME" "$DXMT_URL" "$DXMT_SHA"

# --- 1. Runtime libraries (x86_64) from the pinned Gcenx build -----------------------------------------
rm -rf "$WORK/runtime" && mkdir -p "$WORK/runtime"
tar -xJf "$CACHE/$RUNTIME_NAME" -C "$WORK/runtime"
RLIB="$(ls -d "$WORK"/runtime/*.app/Contents/Resources/wine/lib)"
# Link-time copies carry `@rpath/libX.N.dylib` ids so configure records versioned sonames.
DEPS="$WORK/deps"; rm -rf "$DEPS" && mkdir -p "$DEPS/lib" "$DEPS/include"
for pair in libgnutls:libgnutls.30 libfreetype:libfreetype.6 libSDL2:libSDL2-2.0.0 libvulkan:libvulkan.1 libMoltenVK:libMoltenVK; do
  cp "$RLIB/${pair#*:}.dylib" "$DEPS/lib/${pair%%:*}.dylib"; chmod u+w "$DEPS/lib/${pair%%:*}.dylib"
  install_name_tool -id "@rpath/${pair#*:}.dylib" "$DEPS/lib/${pair%%:*}.dylib" 2>/dev/null
done
ln -s "$BREW/opt/freetype/include/freetype2" "$DEPS/include/freetype2"
ln -s "$BREW/opt/gnutls/include/gnutls" "$DEPS/include/gnutls"
ln -s "$BREW/opt/sdl2/include/SDL2" "$DEPS/include/SDL2"

# --- 2. Wine from CrossOver's source -------------------------------------------------------------------
# RESUME=1 continues an earlier build tree (after fixing a failure) instead of starting from scratch.
# Game videos: Wine's Media Foundation decodes with GStreamer (winegstreamer). MaPC doesn't ship GStreamer; users
# install the official GStreamer.framework themselves (gstreamer.freedesktop.org, universal) and winegstreamer.so
# finds it through this rpath, like Gcenx's engine 1.x. Building needs the GStreamer "devel" package on this Mac.
GST_FW=/Library/Frameworks/GStreamer.framework
GST_PC="$GST_FW/Versions/1.0/bin/pkg-config"
GST_MODULES="gstreamer-1.0 gstreamer-base-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0"
[ -x "$GST_PC" ] && "$GST_PC" --exists $GST_MODULES \
  || { echo "GStreamer devel isn't installed ($GST_FW); install gstreamer-1.0-devel-*-universal.pkg" >&2; exit 1; }
GST_CFLAGS="$("$GST_PC" --cflags $GST_MODULES)"; GST_LIBS="$("$GST_PC" --libs $GST_MODULES)"
CLEAN_ENV=(/usr/bin/env -i HOME="$HOME" PATH="$BREW/opt/bison/bin:$BREW/bin:/usr/bin:/bin:/usr/sbin:/sbin" MACOSX_DEPLOYMENT_TARGET=14.0)
if [ "${RESUME:-0}" != 1 ] || [ ! -f "$WORK/build/Makefile" ]; then
  rm -rf "$WORK/sources/wine" "$WORK/build"
  tar -xzf "$CACHE/$CX_NAME" -C "$WORK" sources/wine
  mkdir -p "$WORK/build"
  ( cd "$WORK/build" && "${CLEAN_ENV[@]}" \
      CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
      FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
      GNUTLS_CFLAGS="-I$DEPS/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
      SDL2_CFLAGS="-I$DEPS/include/SDL2 -D_THREAD_SAFE" SDL2_LIBS="-L$DEPS/lib -lSDL2" \
      GSTREAMER_CFLAGS="$GST_CFLAGS" GSTREAMER_LIBS="$GST_LIBS" \
      LDFLAGS="-L$DEPS/lib -Wl,-rpath,@loader_path/../../ -Wl,-rpath,$GST_FW/Libraries" \
      ac_cv_func_pipe2=no \
      ../sources/wine/configure --build=x86_64-apple-darwin --host=x86_64-apple-darwin --prefix="$WORK/stage" \
        --enable-archs=i386,x86_64 --disable-tests --disable-win16 \
        --with-mingw --with-freetype --with-gnutls --with-sdl --with-vulkan --with-coreaudio --with-opencl --with-unwind \
        --without-x --without-wayland --without-alsa --without-oss --without-udev --without-v4l2 --without-capi \
        --without-inotify --without-pulse --without-dbus --without-netapi --without-krb5 --without-gssapi \
        --without-fontconfig --without-sane --without-gphoto --with-gstreamer --without-ffmpeg --without-usb \
        > configure.out 2>&1 ) || { echo "configure failed; see $WORK/build/configure.out" >&2; exit 1; }
fi
# Build-time tools (sfnt2fon links FreeType) get the same `@loader_path/../../` rpath as Wine's modules;
# from build/tools/<tool>/ that is the build root, so the runtime libraries go there too.
cp -a "$RLIB"/*.dylib "$WORK/build/"
rm -rf "$WORK/stage"
( cd "$WORK/build" && "${CLEAN_ENV[@]}" make -j"$(sysctl -n hw.ncpu)" > make.out 2>&1 \
  && "${CLEAN_ENV[@]}" make install > install.out 2>&1 ) \
  || { echo "Wine build failed; see $WORK/build/make.out and install.out" >&2; exit 1; }

# The SDK can be newer than the oldest macOS the engine supports (MACOSX_DEPLOYMENT_TARGET). Functions only
# a newer macOS has are weak imports, NULL on older systems: configure saw pipe2 in the macOS 27 SDK and
# engine 2.0.1 crashed at start on every macOS 26 Mac (ntdll server_pipe -> pipe2 -> address 0). Hence
# ac_cv_func_pipe2=no above (Wine falls back to pipe + fcntl), and this check: weak imports in Wine's modules
# must be ones its source guards with an availability check.
GUARDED_WEAK='^(ulock_wait2|availability_version_check|os_sync_wait_on_address|os_sync_wait_on_address_with_timeout|os_sync_wake_by_address_any|clCreateImage2D|clCreateImage3D|clEnqueueBarrier|clEnqueueMarker|clEnqueueWaitForEvents|clUnloadCompiler)$'
for bin in "$WORK"/stage/bin/wine "$WORK"/stage/bin/wineserver "$WORK"/stage/lib/wine/x86_64-unix/*.so; do
  [ -L "$bin" ] && continue
  unguarded="$(dyld_info -imports "$bin" 2>/dev/null | grep weak-import | grep -oE '_[A-Za-z0-9_]+' | sed 's/^_*//' \
    | grep -vE "$GUARDED_WEAK" || true)"
  [ -z "$unguarded" ] || { echo "$(basename "$bin") weak-imports $unguarded: check it is guarded, or pin it off in configure" >&2; exit 1; }
done

otool -L "$WORK/stage/lib/wine/x86_64-unix/winegstreamer.so" 2>/dev/null | grep -q 'libgstreamer-1.0' \
  || { echo "winegstreamer.so wasn't built against GStreamer; game videos wouldn't play" >&2; exit 1; }

# --- 3. Assemble the engine ----------------------------------------------------------------------------
ENG="$WORK/engine"; rm -rf "$ENG" && mkdir -p "$ENG"
cp -R "$WORK/stage" "$ENG/wine"
W="$ENG/wine"
rm -rf "$W/include" "$W/share/man" "$W/share/applications"      # build-time only
find "$W/lib/wine" -name "*.a" -delete
cp -a "$RLIB"/*.dylib "$W/lib/"
# Wine dlopens these by leaf name, which dyld resolves through the calling module's rpaths. Wine adds
# `@loader_path/`; LDFLAGS above adds `@loader_path/../../` (= wine/lib, like the 1.x engine). Check it,
# since a missing rpath only shows up later as broken fonts or TLS.
for so in ntdll win32u bcrypt winebus; do
  cmds="$(otool -l "$W/lib/wine/x86_64-unix/$so.so")"
  grep -q "path @loader_path/../../ " <<<"$cmds" || { echo "no rpath in $so.so" >&2; exit 1; }
done
for lib in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libvulkan.1.dylib; do
  [ -f "$W/lib/$lib" ] || { echo "runtime library missing: $lib" >&2; exit 1; }
done
# No library reference or rpath may point back into this build machine's folders. (Wine's loader also
# keeps the configure prefix as text, only to compute relative paths; that is harmless.)
for bin in "$W"/bin/wine "$W"/bin/wineserver "$W"/lib/wine/x86_64-unix/*; do
  [ -L "$bin" ] && continue
  refs="$(otool -L "$bin" | tail -n +2; otool -l "$bin" | grep -A2 LC_RPATH || true)"
  if grep -qF "$WORK" <<<"$refs"; then
    echo "build path leaked into $bin" >&2; exit 1
  fi
done

# DXMT. d3d11/d3d10core/dxgi go beside Wine (lib/dxmt) and into each environment as native DLLs at launch
# (NativeBackendDLLs), so they never replace Wine's or D3DMetal's. winemetal (its bridge to Metal) is a
# builtin. NVIDIA's DLSS/NVAPI stand-ins (nvngx, nvapi64) are left out.
tar -xzf "$CACHE/$DXMT_NAME" -C "$WORK"
DXMT="$WORK/v0.80"
for arch in x86_64 i386; do
  mkdir -p "$W/lib/dxmt/$arch-windows"
  cp "$DXMT/$arch-windows/"{d3d11,d3d10core,dxgi}.dll "$W/lib/dxmt/$arch-windows/"
  cp "$DXMT/$arch-windows/winemetal.dll" "$W/lib/wine/$arch-windows/"
done
cp "$DXMT/x86_64-unix/winemetal.so" "$W/lib/wine/x86_64-unix/"
nm -gU "$W/lib/wine/x86_64-unix/winemac.so" | grep -q " _macdrv_functions$" \
  || { echo "winemac.so doesn't export macdrv_functions; DXMT can't create its Metal view" >&2; exit 1; }

# Steam web helper wrapper (software rendering for Steam's CEF UI, spike finding).
x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static -o "$ENG/steamwebhelper-wrapper.exe" steamwebhelper-wrapper/wrapper.c

# License texts and notices for everything in the engine (licenses/), plus how this build was made:
# the LGPL's "scripts used to control compilation" ship with the binaries.
mkdir -p "$ENG/licenses/build"
cp licenses/* "$ENG/licenses/"
# Libraries Wine builds into its own DLLs (libs/ in the CrossOver source this engine is built from).
mkdir -p "$ENG/licenses/wine-libs"
for f in "$WORK"/sources/wine/libs/*/{COPYING,LICENSE,COPYRIGHT}*; do
  [ -f "$f" ] && cp "$f" "$ENG/licenses/wine-libs/$(basename "$(dirname "$f")")-$(basename "$f").txt"
done
cp build-engine-d3dmetal.sh manifest-add.py steamwebhelper-wrapper/wrapper.c "$ENG/licenses/build/"
cat > "$ENG/licenses/NOTICE.txt" <<TXT
MaPC engine $VERSION. Third-party software and licenses: THIRD-PARTY-NOTICES.md (this folder).
Wine (LGPL-2.1+), built unmodified from CodeWeavers' CrossOver $CX_VERSION source: $CX_URL
  (sha256 $CX_SHA). That tarball is also published with this engine's release:
  https://github.com/abduzeedo/mapc-site/releases/tag/engine-$VERSION
  The build script is in build/ (build-engine-d3dmetal.sh), with the runtime pins it uses.
DXMT v0.80 (MIT), unmodified from $DXMT_URL (sha256 $DXMT_SHA).
No Apple software is included. DirectX 12 uses Apple's D3DMetal, which MaPC copies from the user's own
  download of Apple's Game Porting Toolkit; the user's use of it is governed by Apple's license.
Source offer: support@mapc.games, for at least three years (see THIRD-PARTY-NOTICES.md).
TXT
cat > "$ENG/ENGINE.json" <<JSON
{ "version": "$VERSION", "wineVersion": "11.0, from CrossOver $CX_VERSION source", "backends": ["d3dMetal", "dxmt"], "minMacOS": "14.0" }
JSON

# --- 4. Package and add to the manifest ----------------------------------------------------------------
ARCHIVE="$OUT/macade-engine-$VERSION.tar.xz"
rm -f "$ARCHIVE"
XZ_OPT="-T0 -6" tar -cJf "$ARCHIVE" -C "$ENG" .
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"; SIZE="$(stat -f%z "$ARCHIVE")"
BASE="${MANIFEST_BASE_URL:-file://$OUT}"
./manifest-add.py "$OUT/engine-manifest.json" "$VERSION" "$BASE/macade-engine-$VERSION.tar.xz" "$SHA" "$SIZE" d3dMetal,dxmt
echo "engine:   $ARCHIVE ($((SIZE / 1048576)) MB)"; echo "sha256:   $SHA"; echo "manifest: $OUT/engine-manifest.json"
