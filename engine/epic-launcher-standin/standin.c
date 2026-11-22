// Stand-in for the Epic Games Launcher: starts the program named in its first argument (with the remaining
// arguments) as its own child, and waits for it.
//
// Rockstar's games bought on Epic only count as owned when the Rockstar Games Launcher sees the Epic Games Launcher
// as the process that started the game: it opens its parent process and reads it. Legendary starts the game straight
// from Wine, so the check fails ("Could not do OpenProcess on parent process", "Relaunch from third party platform
// required"), the launcher can't hand the game back to Epic, and RDR2 shows "Buy now" (2026-11-21 report).
// MaPC copies this program into the Epic environment as C:\windows\command\EpicGamesLauncher.exe and has Legendary put
// it in front of the game (LEGENDARY_WRAPPER_EXE). Same approach as Heroic's heroic-epic-integration (MIT).
//
// Build: x86_64-w64-mingw32-gcc -O2 -Wall -municode -mwindows -static -o EpicGamesLauncher.exe standin.c
#include <windows.h>
#include <shellapi.h>
#include <wchar.h>
#include <stdlib.h>

// MaPC looks for this to tell its own copy from anything else at that path.
__attribute__((used)) static const char version_tag[] = "mapc-epic-launcher-standin/1";

#define CP_UNIXCP 65010 /* Wine extension: the Unix code page */

// Legendary passes the game as a Unix path ("/Volumes/.../PlayRDR2.exe"); Windows programs need "Z:\...".
static wchar_t *dos_path(const wchar_t *unix_path) {
    typedef wchar_t *(CDECL *get_dos_name)(const char *);
    get_dos_name convert = (get_dos_name)GetProcAddress(GetModuleHandleW(L"kernel32"), "wine_get_dos_file_name");
    if (!convert) return NULL;
    int n = WideCharToMultiByte(CP_UNIXCP, 0, unix_path, -1, NULL, 0, NULL, NULL);
    char *bytes = n ? malloc(n) : NULL;
    if (!bytes || !WideCharToMultiByte(CP_UNIXCP, 0, unix_path, -1, bytes, n, NULL, NULL)) { free(bytes); return NULL; }
    wchar_t *dos = convert(bytes);
    free(bytes);
    return dos;
}

// Appends one argument quoted the way CommandLineToArgvW reads it back.
static void append_quoted(wchar_t *out, const wchar_t *arg) {
    if (*out) wcscat(out, L" ");
    if (*arg && !wcspbrk(arg, L" \t\n\v\"")) { wcscat(out, arg); return; }
    size_t o = wcslen(out);
    out[o++] = L'"';
    for (const wchar_t *p = arg; ; p++) {
        size_t slashes = 0;
        while (*p == L'\\') { p++; slashes++; }
        if (!*p) { while (slashes--) { out[o++] = L'\\'; out[o++] = L'\\'; } break; }
        if (*p == L'"') { slashes = slashes * 2 + 1; }
        while (slashes--) out[o++] = L'\\';
        out[o++] = *p;
    }
    out[o++] = L'"';
    out[o] = 0;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show) {
    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 2) return 1;

    wchar_t *converted = argv[1][0] == L'/' ? dos_path(argv[1]) : NULL;
    const wchar_t *exe = converted ? converted : argv[1];

    size_t len = wcslen(exe) * 2 + 3;
    for (int i = 2; i < argc; i++) len += wcslen(argv[i]) * 2 + 3;
    wchar_t *line = calloc(len + 1, sizeof(wchar_t));
    if (!line) return 1;
    append_quoted(line, exe);
    for (int i = 2; i < argc; i++) append_quoted(line, argv[i]);

    // Games expect to start in their own folder, as they do from the Epic Games Launcher.
    wchar_t *dir = _wcsdup(exe), *slash = dir ? wcsrchr(dir, L'\\') : NULL;
    if (slash) *slash = 0;

    STARTUPINFOW si = { .cb = sizeof(si) };
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(exe, line, NULL, NULL, FALSE, 0, NULL, slash ? dir : NULL, &si, &pi)) return 1;
    CloseHandle(pi.hThread);
    // Stay alive: the launcher checks this process while the game starts, and Legendary's Wine session ends with us.
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return (int)code;
}
