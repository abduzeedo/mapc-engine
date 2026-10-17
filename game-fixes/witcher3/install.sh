#!/usr/bin/env bash
# The Witcher 3 (patch 5.00b/c, DX12) on D3DMetal: workaround for a crash in Apple's shader converter.
# At startup the game builds one stream-output pipeline (geometry shader, no pixel shader); D3DMetal 3.0
# crashes compiling it, which leaves a black screen. `ffxproxy.c` (MIT, tholtman1-del/witcher3-crossover-fix,
# commit in UPSTREAM_COMMIT; reviewed: no network, no child processes, writes only a log in the Windows
# profile) stands in for the game's amd_fidelityfx_loader_dx12.dll, forwards every FidelityFX call to the
# original, and refuses that one pipeline. One visual effect may be missing.
#
#   game-fixes/witcher3/install.sh              build from source here and install (original kept)
#   game-fixes/witcher3/install.sh --uninstall  put the original back
# Steam's "Verify integrity of game files", or a game update, also restores the original; run again after.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME="${WITCHER3_DIR:-$HOME/Library/Application Support/Macade/Bottles/steam/drive_c/Program Files (x86)/Steam/steamapps/common/The Witcher 3}"
BIN="$GAME/bin/x64_dx12"
DLL="amd_fidelityfx_loader_dx12.dll"; ORIG="amd_fidelityfx_loader_dx12_orig.dll"; MARK="ffxproxy attached"

[ -f "$BIN/witcher3.exe" ] || { echo "The Witcher 3 isn't at: $BIN (set WITCHER3_DIR)" >&2; exit 1; }
if pgrep -f 'witcher3\.exe' >/dev/null; then echo "Close The Witcher 3 first." >&2; exit 1; fi

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$BIN/$ORIG" ]; then mv -f "$BIN/$ORIG" "$BIN/$DLL"; echo "Restored the game's original $DLL."
  else echo "Nothing to undo (no $ORIG)."; fi
  exit 0
fi

command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "need mingw-w64 (brew install mingw-w64)" >&2; exit 1; }
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
x86_64-w64-mingw32-gcc -shared -O2 -Wall -static-libgcc -o "$OUT/$DLL" "$HERE/ffxproxy.c"
# It must export the FidelityFX entry points the game imports, and import only standard Windows DLLs.
info="$(x86_64-w64-mingw32-objdump -p "$OUT/$DLL")"
for fn in ffxCreateContext ffxDestroyContext ffxConfigure ffxQuery ffxDispatch; do
  grep -qE "[[:space:]]$fn$" <<<"$info" || { echo "built DLL lacks export $fn" >&2; exit 1; }
done
imports="$(grep "DLL Name:" <<<"$info" | awk '{print tolower($3)}' | sort -u | tr '\n' ' ')"
for dll in $imports; do
  case "$dll" in kernel32.dll|msvcrt.dll|user32.dll|api-ms-win-*) ;; *) echo "unexpected import: $dll" >&2; exit 1;; esac
done

if grep -q "$MARK" "$BIN/$DLL" 2>/dev/null; then
  echo "Workaround already installed; updating it."
else
  # The file there is the game's (first install, or restored by an update/verify): keep it as the original.
  mv -f "$BIN/$DLL" "$BIN/$ORIG"
fi
cp "$OUT/$DLL" "$BIN/$DLL"
echo "Installed. Original kept as $ORIG. Imports: $imports"
echo "Log: drive_c/users/<you>/ffxproxy.log in the Steam bottle."
