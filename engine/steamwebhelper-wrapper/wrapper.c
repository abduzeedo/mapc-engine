// Chromium helper wrapper: re-launches the real helper (<own name>_real.exe) with extra Chromium flags.
// Wine's CEF paints black windows with GPU compositing, so we force software rendering.
// Used for Steam's steamwebhelper.exe and Rockstar's SocialClubHelper.exe.
// Build: x86_64-w64-mingw32-gcc -O2 -municode -mwindows -static -o steamwebhelper.exe wrapper.c
#include <windows.h>
#include <wchar.h>
#include <stdlib.h>

#ifndef EXTRA_FLAGS
#define EXTRA_FLAGS L" --disable-gpu --disable-gpu-compositing --in-process-gpu"
#endif

// MaPC looks for this to tell the generic wrapper from the old steamwebhelper-only one.
__attribute__((used)) static const char version_tag[] = "macade-chromium-wrapper/2";

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show) {
    wchar_t self[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return 1;
    // foo.exe -> foo_real.exe
    wchar_t *slash = wcsrchr(self, L'\\');
    wchar_t *dot = wcsrchr(self, L'.');
    if (!slash || !dot || dot < slash || _wcsicmp(dot, L".exe") != 0) return 1;
    if (n + wcslen(L"_real") >= MAX_PATH) return 1;
    wcscpy(dot, L"_real.exe");

    const wchar_t *orig = GetCommandLineW();
    size_t len = wcslen(orig) + wcslen(self) + wcslen(EXTRA_FLAGS) + 8;
    wchar_t *line = calloc(len, sizeof(wchar_t));
    if (!line) return 1;

    // Skip argv[0] in the original command line, keep the rest verbatim.
    const wchar_t *p = orig;
    if (*p == L'"') { p++; while (*p && *p != L'"') p++; if (*p) p++; }
    else { while (*p && *p != L' ') p++; }

    // Subprocesses (--type=...) get the same flags; the browser process needs them too.
    swprintf(line, len, L"\"%ls\"%ls%ls", self, p, EXTRA_FLAGS);

    STARTUPINFOW si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(self, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
