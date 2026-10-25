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

// Direct3D DLLs a game's backend overrides (DXVK, DXMT). Steam started for a game inherits the game's
// WINEDLLOVERRIDES, and Chromium crashes on DXMT's dxgi/d3d11 at every start. Without the override Wine's
// builtins win over the native copies in System32, so the helper gets WineD3D.
static const wchar_t *const kept_builtin[] = { L"dxgi", L"d3d11", L"d3d10core", L"d3d10", L"d3d10_1" };

static int is_kept_builtin(const wchar_t *name, size_t len) {
    for (size_t i = 0; i < sizeof(kept_builtin) / sizeof(*kept_builtin); i++)
        if (wcslen(kept_builtin[i]) == len && _wcsnicmp(name, kept_builtin[i], len) == 0) return 1;
    return 0;
}

// "mscoree,mshtml=;dxgi,d3d11,d3d10core=n,b" -> "mscoree,mshtml=". Entries are "dll[,dll...]=mode".
static void drop_direct3d_overrides(void) {
    DWORD n = GetEnvironmentVariableW(L"WINEDLLOVERRIDES", NULL, 0);
    if (n == 0) return;
    wchar_t *in = calloc(n, sizeof(wchar_t)), *out = calloc(n + 1, sizeof(wchar_t));
    if (!in || !out || GetEnvironmentVariableW(L"WINEDLLOVERRIDES", in, n) >= n) { free(in); free(out); return; }
    size_t o = 0;
    for (wchar_t *entry = in; *entry; ) {
        wchar_t *end = entry + wcscspn(entry, L";");
        wchar_t *eq = entry + wcscspn(entry, L"=");
        if (eq > end) eq = end;
        size_t start = o, kept = 0;
        if (o) out[o++] = L';';
        for (wchar_t *name = entry; name < eq; ) {
            wchar_t *comma = name + wcscspn(name, L",");
            if (comma > eq) comma = eq;
            if (comma > name && !is_kept_builtin(name, comma - name)) {
                if (kept++) out[o++] = L',';
                wmemcpy(out + o, name, comma - name); o += comma - name;
            }
            name = comma < eq ? comma + 1 : eq;
        }
        if (kept) { wmemcpy(out + o, eq, end - eq); o += end - eq; }
        else o = start;   // every DLL in this entry was dropped
        entry = *end ? end + 1 : end;
    }
    out[o] = 0;
    SetEnvironmentVariableW(L"WINEDLLOVERRIDES", out);
    free(in); free(out);
}

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

    drop_direct3d_overrides();   // inherited by the real helper and its subprocesses
    STARTUPINFOW si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(self, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
