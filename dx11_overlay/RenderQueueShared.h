#pragma once

#include <Windows.h>
#include <cstdint>

namespace GH2 {

constexpr wchar_t kRenderQueueMapName[] = L"Local\\PoE2GH_RenderQueue_v1";
constexpr wchar_t kRenderQueueMutexName[] = L"Local\\PoE2GH_RenderQueueMutex_v1";
constexpr uint32_t kRenderQueueCapacity = 2048;

enum class RenderOpType : uint32_t {
    Rect = 1,
    FilledRect = 2,
    Text = 3,
    HealthBar = 4,
};

constexpr uint32_t kRenderOpTextCapacity = 96;

#pragma pack(push, 1)
struct RenderOp {
    RenderOpType type;
    float x;
    float y;
    float w;
    float h;
    float value;      // e.g. health pct
    uint32_t color;
    char text[kRenderOpTextCapacity];
};
#pragma pack(pop)

static_assert(sizeof(RenderOp) == 124, "RenderOp size mismatch");

struct RenderQueueHeader {
    uint32_t magic;
    uint32_t writeIndex;
    uint32_t count;
    RenderOp ops[kRenderQueueCapacity];
};

constexpr uint32_t kRenderQueueMagic = 0x51475248; // "HRGQ"

} // namespace GH2
