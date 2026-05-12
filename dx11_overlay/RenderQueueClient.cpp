#include "RenderQueueShared.h"
#include <algorithm>

namespace GH2 {

static HANDLE gMap = nullptr;
static HANDLE gMutex = nullptr;
static RenderQueueHeader* gHeader = nullptr;

bool ConnectRenderQueue()
{
    if (gHeader) return true;

    gMap = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, kRenderQueueMapName);
    if (!gMap) {
        gMap = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(RenderQueueHeader), kRenderQueueMapName);
        if (!gMap) return false;
    }

    gHeader = reinterpret_cast<RenderQueueHeader*>(MapViewOfFile(gMap, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(RenderQueueHeader)));
    if (!gHeader) return false;

    gMutex = CreateMutexW(nullptr, FALSE, kRenderQueueMutexName);
    if (!gMutex) return false;

    if (gHeader->magic != kRenderQueueMagic) {
        gHeader->magic = kRenderQueueMagic;
        gHeader->writeIndex = 0;
        gHeader->count = 0;
    }

    return true;
}

void DisconnectRenderQueue()
{
    if (gHeader) {
        UnmapViewOfFile(gHeader);
        gHeader = nullptr;
    }
    if (gMap) {
        CloseHandle(gMap);
        gMap = nullptr;
    }
    if (gMutex) {
        CloseHandle(gMutex);
        gMutex = nullptr;
    }
}

uint32_t PopAll(RenderOp* outOps, uint32_t outCapacity)
{
    if (!gHeader || !gMutex || outCapacity == 0) return 0;

    if (WaitForSingleObject(gMutex, 5) != WAIT_OBJECT_0) return 0;

    uint32_t n = std::min(gHeader->count, outCapacity);
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t idx = (gHeader->writeIndex + kRenderQueueCapacity - gHeader->count + i) % kRenderQueueCapacity;
        outOps[i] = gHeader->ops[idx];
    }
    gHeader->count = 0;

    ReleaseMutex(gMutex);
    return n;
}

} // namespace GH2
