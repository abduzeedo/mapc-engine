# MaPC game engines: third-party software

MaPC's engines are made of the free and open-source software below. Each component keeps its own license; the
full texts are the other files in this folder. Nothing here is MaPC's own code except the small Chromium helper
wrapper (`steamwebhelper-wrapper.exe`), which is © Steale LLC and open source under the Apache License 2.0
(MacadeKit, `engine/steamwebhelper-wrapper`).

**No Apple software is included in any MaPC engine.** DirectX 12 support uses Apple's D3DMetal, which MaPC copies
from the user's own download of Apple's Game Porting Toolkit; the user's use of it is governed by Apple's license.

## Source code

- **Wine in engine 2.x** is built by us, unmodified, from CodeWeavers' CrossOver 26.3.0 source
  (`crossover-sources-26.3.0.tar.gz`). That tarball and our build script are published next to the engine on its
  GitHub release (https://github.com/abduzeedo/mapc-site/releases).
- **Wine Staging in engine 1.x** and the **runtime libraries** in both engines (everything under "Runtime libraries"
  below) are Gcenx's macOS builds, version 11.18: https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18
  (libraries built with MacPorts; their sources are MacPorts' distfiles for those versions).
- **DXVK** in engine 1.x: https://github.com/Gcenx/DXVK-macOS/releases/tag/v1.10.3-20230507-repack
- **DXMT** in engine 2.x: v0.80, the unmodified release build from https://github.com/3Shain/dxmt/releases/tag/v0.80
  (source: https://github.com/3Shain/dxmt/tree/v0.80). Its `winemetal.so` contains LLVM 15, its shader converter
  contains Microsoft's DXBC parser, and parts of it are derived from DXVK.

**Written offer.** For at least three years after we last distribute an engine, anyone who received it can ask us
for the complete corresponding source code of any LGPL or GPL component in it, for no more than the cost of
providing it: email support@mapc.games.

## Components

| Component | Engine | License | Text |
|---|---|---|---|
| Wine (CodeWeavers CrossOver 26.3.0 source) | 2.x | LGPL-2.1-or-later | Wine-COPYING.LIB.txt, Wine-LICENSE.txt |
| Wine Staging 11.18 | 1.x | LGPL-2.1-or-later | Wine-COPYING.LIB.txt, Wine-LICENSE.txt |
| DXVK (macOS, async) 1.10.3 | 1.x | zlib | DXVK-LICENSE.txt |
| winpthreads (mingw-w64 11.0.1, linked into DXVK's DLLs) | 1.x | MIT-style and BSD-style | winpthreads-COPYING.txt |
| DXMT 0.80 | 2.x | MIT | DXMT-LICENSE.txt |
| LLVM 15 (inside DXMT's `winemetal.so`) | 2.x | Apache-2.0 WITH LLVM-exception | LLVM-LICENSE.txt |
| DXBC parser (Microsoft, inside DXMT) | 2.x | MIT | DXBCParser-LICENSE.txt |
| DXVK-derived code in DXMT | 2.x | zlib | DXVK-LICENSE.txt |
| MoltenVK | both | Apache-2.0 | MoltenVK-LICENSE.txt |
| Vulkan Loader | both | Apache-2.0 | Vulkan-Loader-LICENSE.txt |
| SDL2 | both | zlib | SDL2-LICENSE.txt |
| FreeType | both | FreeType License (FTL) | freetype-LICENSE.txt |

### Runtime libraries (both engines)

| Library | License | Text |
|---|---|---|
| GnuTLS | LGPL-2.1-or-later | gnutls-COPYING.LESSERv2.txt |
| Nettle, Hogweed | LGPL-3.0-or-later or GPL-2.0-or-later (used under LGPL-3.0) | nettle-COPYING.LESSERv3.txt, GPL-3.0.txt |
| GMP | LGPL-3.0-or-later or GPL-2.0-or-later (used under LGPL-3.0) | gmp-COPYING.LESSERv3.txt, GPL-3.0.txt |
| libtasn1 | LGPL-2.1-or-later | libtasn1-COPYING.LESSERv2.txt |
| libidn2 | LGPL-3.0-or-later or GPL-2.0-or-later (used under LGPL-3.0) | libidn2-COPYING.LESSERv3.txt, GPL-3.0.txt |
| libunistring | LGPL-3.0-or-later or GPL-2.0-or-later | libunistring-COPYING.LIB.txt, GPL-3.0.txt |
| libiconv, libcharset | LGPL-2.1-or-later | LGPL-2.1.txt |
| libintl (gettext runtime) | LGPL-2.1-or-later | LGPL-2.1.txt |
| p11-kit | BSD-3-Clause | p11-kit-COPYING.txt |
| ICU 76 | Unicode License v3 | icu-LICENSE.txt |
| libxml2 | MIT | libxml2-Copyright.txt |
| libxslt, libexslt | MIT | libxslt-Copyright.txt |
| libffi | MIT | libffi-LICENSE.txt |
| libinotify-kqueue | MIT | libinotify-kqueue-LICENSE.txt |
| libpng | libpng License | libpng-LICENSE.txt |
| zlib | zlib | zlib-LICENSE.txt |
| bzip2 | bzip2 License (BSD-style) | bzip2-LICENSE.txt |
| xz (liblzma) | 0BSD | xz-COPYING.txt, xz-COPYING.0BSD.txt |
| lz4 | BSD-2-Clause | lz4-LICENSE.txt |
| zstd | BSD-3-Clause | zstd-LICENSE.txt |
| Brotli | MIT | brotli-LICENSE.txt |
| libpcap | BSD-3-Clause | libpcap-LICENSE.txt |
| MacPorts legacy support | Various, per source file (including APSL-2.0) | macports-legacy-support-LICENSE.txt; source: https://github.com/macports/macports-legacy-support |
