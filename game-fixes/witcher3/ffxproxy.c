// Proxy for amd_fidelityfx_loader_dx12.dll (The Witcher 3 5.00b under CrossOver/D3DMetal).
// Forwards all FFX API calls to the real loader (amd_fidelityfx_loader_dx12_orig.dll).
// On the first ffxQuery(GET_VERSIONS) it hooks the game's ID3D12Device and refuses
// stream-output pipelines (GS without PS / SO entries): compiling those crashes Apple's
// D3DMetal shader converter (libmetalirconverter), which hangs the game on a black screen.
// Env knobs: FFXPROXY_DUMP=1 dumps shaders to %USERPROFILE%\ffxdump,
//            FFXPROXY_STUB_FSR=1 gives FSR upscale/framegen a dummy context.
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

typedef struct ffxApiHeader { uint64_t type; struct ffxApiHeader *pNext; } ffxApiHeader;
typedef void *ffxContext;
typedef uint32_t ffxReturnCode_t;
typedef struct ffxAllocationCallbacks ffxAllocationCallbacks;

typedef ffxReturnCode_t (*PfnCreate)(ffxContext *, ffxApiHeader *, const ffxAllocationCallbacks *);
typedef ffxReturnCode_t (*PfnDestroy)(ffxContext *, const ffxAllocationCallbacks *);
typedef ffxReturnCode_t (*PfnConfigure)(ffxContext *, const ffxApiHeader *);
typedef ffxReturnCode_t (*PfnQuery)(ffxContext *, ffxApiHeader *);
typedef ffxReturnCode_t (*PfnDispatch)(ffxContext *, const ffxApiHeader *);

#define RET_OK 0u
#define RET_ERROR 1u

#define DESC_CREATE_UPSCALE 0x00010000u
#define DESC_CREATE_FRAMEGENERATION 0x00020001u
#define DESC_QUERY_GET_PROVIDER_VERSION 6u
#define DESC_QUERY_UPSCALE_GPU_MEMORY_USAGE 0x00010008u
#define DESC_QUERY_UPSCALE_GPU_MEMORY_USAGE_V2 0x00010009u
#define DESC_QUERY_FG_GPU_MEMORY_USAGE 0x00020007u
#define DESC_QUERY_FG_GPU_MEMORY_USAGE_V2 0x0002000bu

#define DUMMY_MAGIC 0x59444d4d55444646ull /* "FFDUMMY" */

typedef struct DummyCtx { uint64_t magic; uint64_t createType; } DummyCtx;

struct ffxQueryGetProviderVersion { ffxApiHeader header; uint64_t versionId; const char *versionName; };
struct FfxApiEffectMemoryUsage { uint64_t totalUsageInBytes; uint64_t aliasableUsageInBytes; };
struct ffxQueryGpuMemoryUsage { ffxApiHeader header; struct FfxApiEffectMemoryUsage *usage; };

static HMODULE real;
static PfnCreate pCreate;
static PfnDestroy pDestroy;
static PfnConfigure pConfigure;
static PfnQuery pQuery;
static PfnDispatch pDispatch;
static FILE *logf;
static CRITICAL_SECTION lock;

static void logmsg(const char *fmt, ...)
{
    if (!logf) return;
    va_list ap;
    va_start(ap, fmt);
    EnterCriticalSection(&lock);
    fprintf(logf, "[%lu] ", GetTickCount());
    vfprintf(logf, fmt, ap);
    fputc('\n', logf);
    fflush(logf);
    LeaveCriticalSection(&lock);
    va_end(ap);
}

static void load_real(void)
{
    if (real) return;
    char path[MAX_PATH];
    HMODULE self = NULL;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCSTR)&load_real, &self);
    DWORD n = GetModuleFileNameA(self, path, MAX_PATH);
    while (n && path[n - 1] != '\\' && path[n - 1] != '/') n--;
    path[n] = 0;
    strcat(path, "amd_fidelityfx_loader_dx12_orig.dll");
    real = LoadLibraryA(path);
    if (!real) { logmsg("failed to load %s (err %lu)", path, GetLastError()); return; }
    pCreate = (PfnCreate)GetProcAddress(real, "ffxCreateContext");
    pDestroy = (PfnDestroy)GetProcAddress(real, "ffxDestroyContext");
    pConfigure = (PfnConfigure)GetProcAddress(real, "ffxConfigure");
    pQuery = (PfnQuery)GetProcAddress(real, "ffxQuery");
    pDispatch = (PfnDispatch)GetProcAddress(real, "ffxDispatch");
    logmsg("loaded real loader %s", path);
}

/* ---- D3D12 device hooks: log + dump shaders before D3DMetal compiles them ---- */

typedef struct { const void *p; SIZE_T n; } Bytecode;
typedef long (__stdcall *PfnCreateGfxPSO)(void *dev, const void *desc, const void *riid, void **out);
typedef long (__stdcall *PfnCreateCsPSO)(void *dev, const void *desc, const void *riid, void **out);
typedef long (__stdcall *PfnCreatePSO)(void *dev, const void *desc, const void *riid, void **out);
typedef long (__stdcall *PfnCreateStateObject)(void *dev, const void *desc, const void *riid, void **out);
typedef long (__stdcall *PfnCreatePipelineLibrary)(void *dev, const void *blob, SIZE_T len, const void *riid, void **out);

static PfnCreateGfxPSO origGfx;
static PfnCreateCsPSO origCs;
static PfnCreatePSO origPso;
static PfnCreateStateObject origSo;
static PfnCreatePipelineLibrary origLib;
static volatile LONG psoCounter;
static char dumpDir[MAX_PATH];

static uint32_t fnv1a(const void *p, SIZE_T n)
{
    const unsigned char *b = (const unsigned char *)p;
    uint32_t h = 2166136261u;
    for (SIZE_T i = 0; i < n; i++) { h ^= b[i]; h *= 16777619u; }
    return h;
}

static void dump_shader(LONG id, const char *stage, Bytecode bc)
{
    if (!bc.p || !bc.n || !getenv("FFXPROXY_DUMP")) return;
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%s\\pso%05ld_%s_%08x.dxil", dumpDir, id, stage, fnv1a(bc.p, bc.n));
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(bc.p, 1, bc.n, f); fclose(f); }
    logmsg("  pso %ld %s size=%zu hash=%08x", id, stage, (size_t)bc.n, fnv1a(bc.p, bc.n));
}

static long __stdcall hkGfx(void *dev, const void *desc, const void *riid, void **out)
{
    LONG id = InterlockedIncrement(&psoCounter);
    const char *d = (const char *)desc;
    static const char *stages[] = { "vs", "ps", "ds", "hs", "gs" };
    logmsg("CreateGraphicsPipelineState #%ld tid=%lu", id, GetCurrentThreadId());
    for (int i = 0; i < 5; i++) dump_shader(id, stages[i], *(const Bytecode *)(d + 8 + 16 * i));
    const Bytecode *ps = (const Bytecode *)(d + 8 + 16);
    const Bytecode *gs = (const Bytecode *)(d + 8 + 16 * 4);
    uint32_t soEntries = *(const uint32_t *)(d + 96);
    uint32_t soStrides = *(const uint32_t *)(d + 112);
    uint32_t soRaster = *(const uint32_t *)(d + 116);
    if (soEntries || gs->n)
        logmsg("  streamout entries=%u strides=%u rasterized=%u", soEntries, soStrides, soRaster);
    if (gs->n && (soEntries || !ps->n)) {
        logmsg("  -> #%ld SKIPPED (stream output / GS without PS)", id);
        if (out) *out = NULL;
        return (long)0x80070057; /* E_INVALIDARG */
    }
    long hr = origGfx(dev, desc, riid, out);
    logmsg("  -> #%ld hr=0x%08lx", id, hr);
    return hr;
}

static long __stdcall hkCs(void *dev, const void *desc, const void *riid, void **out)
{
    LONG id = InterlockedIncrement(&psoCounter);
    logmsg("CreateComputePipelineState #%ld tid=%lu", id, GetCurrentThreadId());
    dump_shader(id, "cs", *(const Bytecode *)((const char *)desc + 8));
    long hr = origCs(dev, desc, riid, out);
    logmsg("  -> #%ld hr=0x%08lx", id, hr);
    return hr;
}

/* Pipeline state stream: subobjects are pointer-aligned, each starting with a type enum. */
static SIZE_T subobject_size(uint32_t type)
{
    switch (type) {
    case 0: return 8;           /* root signature pointer */
    case 1: case 2: case 3: case 4: case 5: case 6: case 24: case 25: return 16; /* shader bytecode */
    case 7: return 40;          /* stream output */
    case 8: return 328;         /* blend desc */
    case 9: return 4;           /* sample mask */
    case 10: return 44;         /* rasterizer */
    case 11: return 52;         /* depth stencil */
    case 12: return 16;         /* input layout */
    case 13: return 4;          /* strip cut */
    case 14: return 4;          /* topology type */
    case 15: return 36;         /* rtv formats */
    case 16: return 4;          /* dsv format */
    case 17: return 8;          /* sample desc */
    case 18: return 4;          /* node mask */
    case 19: return 16;         /* cached pso */
    case 20: return 4;          /* flags */
    case 21: return 52;         /* depth stencil1 */
    case 22: return 16;         /* view instancing */
    case 26: return 52;         /* depth stencil2 (approx) */
    case 27: return 44;         /* rasterizer1 */
    case 28: return 44;         /* rasterizer2 */
    default: return 0;
    }
}

static long __stdcall hkPso(void *dev, const void *desc, const void *riid, void **out)
{
    LONG id = InterlockedIncrement(&psoCounter);
    SIZE_T size = *(const SIZE_T *)desc;
    const char *stream = *(const char *const *)((const char *)desc + 8);
    static const char *names[] = { "rs", "vs", "ps", "ds", "hs", "gs", "cs" };
    logmsg("CreatePipelineState #%ld tid=%lu stream=%zu bytes", id, GetCurrentThreadId(), (size_t)size);
    SIZE_T off = 0;
    while (off + 4 <= size) {
        uint32_t type = *(const uint32_t *)(stream + off);
        SIZE_T body = subobject_size(type);
        if (!body) { logmsg("  unknown subobject %u at %zu, stop parsing", type, (size_t)off); break; }
        /* subobject structs are aligned to pointer size; body alignment depends on member types */
        SIZE_T align = (type <= 7 || type == 12 || type == 19 || type == 22 || (type >= 24 && type <= 25)) ? 8 : 4;
        SIZE_T bodyOff = (off + 4 + align - 1) & ~(align - 1);
        if ((type >= 1 && type <= 6) || type == 24 || type == 25) {
            const char *stage = type <= 6 ? names[type] : (type == 24 ? "as" : "ms");
            dump_shader(id, stage, *(const Bytecode *)(stream + bodyOff));
        }
        off = (bodyOff + body + 7) & ~(SIZE_T)7;
    }
    long hr = origPso(dev, desc, riid, out);
    logmsg("  -> #%ld hr=0x%08lx", id, hr);
    return hr;
}

static long __stdcall hkSo(void *dev, const void *desc, const void *riid, void **out)
{
    LONG id = InterlockedIncrement(&psoCounter);
    logmsg("CreateStateObject #%ld tid=%lu type=%u", id, GetCurrentThreadId(), *(const uint32_t *)desc);
    long hr = origSo(dev, desc, riid, out);
    logmsg("  -> #%ld hr=0x%08lx", id, hr);
    return hr;
}

static long __stdcall hkLib(void *dev, const void *blob, SIZE_T len, const void *riid, void **out)
{
    logmsg("CreatePipelineLibrary len=%zu tid=%lu", (size_t)len, GetCurrentThreadId());
    long hr = origLib(dev, blob, len, riid, out);
    logmsg("  -> lib hr=0x%08lx", hr);
    return hr;
}

static void patch_slot(void **vtbl, int idx, void *hook, void **orig)
{
    DWORD old;
    if (vtbl[idx] == hook) return;
    VirtualProtect(&vtbl[idx], sizeof(void *), PAGE_EXECUTE_READWRITE, &old);
    *orig = vtbl[idx];
    vtbl[idx] = hook;
    VirtualProtect(&vtbl[idx], sizeof(void *), old, &old);
}

static void hook_device(void *dev)
{
    static LONG done;
    if (!dev || InterlockedExchange(&done, 1)) return;
    void **vtbl = *(void ***)dev;
    patch_slot(vtbl, 10, (void *)hkGfx, (void **)&origGfx);
    patch_slot(vtbl, 11, (void *)hkCs, (void **)&origCs);
    patch_slot(vtbl, 44, (void *)hkLib, (void **)&origLib);
    patch_slot(vtbl, 47, (void *)hkPso, (void **)&origPso);
    patch_slot(vtbl, 62, (void *)hkSo, (void **)&origSo);
    logmsg("hooked D3D12 device %p vtbl %p", dev, vtbl);
}

struct ffxQueryDescGetVersions { ffxApiHeader header; uint64_t createDescType; void *device; uint64_t *outputCount; uint64_t *versionIds; const char **versionNames; };

static int is_dummy(ffxContext *ctx)
{
    return ctx && *ctx && ((DummyCtx *)*ctx)->magic == DUMMY_MAGIC;
}

__declspec(dllexport) ffxReturnCode_t ffxCreateContext(ffxContext *ctx, ffxApiHeader *desc, const ffxAllocationCallbacks *cb)
{
    uint64_t type = desc ? desc->type : 0;
    if (getenv("FFXPROXY_STUB_FSR") && (type == DESC_CREATE_UPSCALE || type == DESC_CREATE_FRAMEGENERATION)) {
        DummyCtx *d = (DummyCtx *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(DummyCtx));
        d->magic = DUMMY_MAGIC;
        d->createType = type;
        *ctx = d;
        logmsg("CreateContext type=0x%llx -> dummy %p", (unsigned long long)type, d);
        return RET_OK;
    }
    load_real();
    ffxReturnCode_t r = pCreate ? pCreate(ctx, desc, cb) : RET_ERROR;
    logmsg("CreateContext type=0x%llx -> forwarded, ret=%u ctx=%p", (unsigned long long)type, r, ctx ? *ctx : NULL);
    return r;
}

__declspec(dllexport) ffxReturnCode_t ffxDestroyContext(ffxContext *ctx, const ffxAllocationCallbacks *cb)
{
    if (is_dummy(ctx)) {
        logmsg("DestroyContext dummy %p", *ctx);
        HeapFree(GetProcessHeap(), 0, *ctx);
        *ctx = NULL;
        return RET_OK;
    }
    load_real();
    ffxReturnCode_t r = pDestroy ? pDestroy(ctx, cb) : RET_ERROR;
    logmsg("DestroyContext forwarded ret=%u", r);
    return r;
}

__declspec(dllexport) ffxReturnCode_t ffxConfigure(ffxContext *ctx, const ffxApiHeader *desc)
{
    if (is_dummy(ctx)) return RET_OK;
    load_real();
    ffxReturnCode_t r = pConfigure ? pConfigure(ctx, desc) : RET_ERROR;
    logmsg("Configure type=0x%llx forwarded ret=%u", (unsigned long long)(desc ? desc->type : 0), r);
    return r;
}

__declspec(dllexport) ffxReturnCode_t ffxQuery(ffxContext *ctx, ffxApiHeader *desc)
{
    uint64_t type = desc ? desc->type : 0;
    if (is_dummy(ctx)) {
        if (type == DESC_QUERY_GET_PROVIDER_VERSION) {
            struct ffxQueryGetProviderVersion *q = (struct ffxQueryGetProviderVersion *)desc;
            q->versionId = 1;
            q->versionName = "3.1.5 (stub)";
        } else if (type == DESC_QUERY_UPSCALE_GPU_MEMORY_USAGE || type == DESC_QUERY_FG_GPU_MEMORY_USAGE) {
            struct ffxQueryGpuMemoryUsage *q = (struct ffxQueryGpuMemoryUsage *)desc;
            if (q->usage) { q->usage->totalUsageInBytes = 0; q->usage->aliasableUsageInBytes = 0; }
        } else {
            // Stateless queries (ratios, jitter, ...) don't need a live context.
            load_real();
            if (pQuery) {
                ffxReturnCode_t r = pQuery(NULL, desc);
                logmsg("Query dummy type=0x%llx -> stateless forward ret=%u", (unsigned long long)type, r);
                return r;
            }
        }
        logmsg("Query dummy type=0x%llx", (unsigned long long)type);
        return RET_OK;
    }
    if (type == 4)
        hook_device(((struct ffxQueryDescGetVersions *)desc)->device);
    load_real();
    ffxReturnCode_t r = pQuery ? pQuery(ctx, desc) : RET_ERROR;
    logmsg("Query type=0x%llx forwarded ret=%u", (unsigned long long)type, r);
    return r;
}

__declspec(dllexport) ffxReturnCode_t ffxDispatch(ffxContext *ctx, const ffxApiHeader *desc)
{
    if (is_dummy(ctx)) return RET_OK;
    load_real();
    ffxReturnCode_t r = pDispatch ? pDispatch(ctx, desc) : RET_ERROR;
    logmsg("Dispatch type=0x%llx forwarded ret=%u", (unsigned long long)(desc ? desc->type : 0), r);
    return r;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&lock);
        char path[MAX_PATH];
        if (GetEnvironmentVariableA("USERPROFILE", path, MAX_PATH)) {
            strcat(path, "\\ffxproxy.log");
            logf = fopen(path, "w");
            GetEnvironmentVariableA("USERPROFILE", dumpDir, MAX_PATH);
            strcat(dumpDir, "\\ffxdump");
            CreateDirectoryA(dumpDir, NULL);
        }
        logmsg("ffxproxy attached");
        /* The game calls SetProcessDPIAware only after it has enumerated display modes, so with
           CrossOver's High Resolution Mode it sees a half-size virtual desktop and caps out at
           1512x982. Declaring DPI awareness this early exposes the real resolutions. */
        if (!getenv("FFXPROXY_NO_DPI")) {
            HMODULE u32 = GetModuleHandleA("user32.dll");
            BOOL (WINAPI *setAware)(void) = u32 ? (BOOL (WINAPI *)(void))GetProcAddress(u32, "SetProcessDPIAware") : NULL;
            logmsg("SetProcessDPIAware %s", setAware && setAware() ? "ok" : "failed");
        }
    }
    return TRUE;
}
