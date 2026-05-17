#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include "imgui.h"
#include "imgui_impl_dx12.h"
#include "imgui_impl_win32.h"
#include "RenderQueueShared.h"
#include "MinHook.h"

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")

using PresentFn       = HRESULT(__stdcall*)(IDXGISwapChain*, UINT, UINT);
using ResizeBuffersFn = HRESULT(__stdcall*)(IDXGISwapChain*, UINT, UINT, UINT, DXGI_FORMAT, UINT);
using ExecCmdListsFn  = void(__stdcall*)(ID3D12CommandQueue*, UINT, ID3D12CommandList* const*);

static PresentFn       oPresent       = nullptr;
static ResizeBuffersFn oResizeBuffers = nullptr;
static ExecCmdListsFn  oExecCmdLists  = nullptr;

static ID3D12Device*              gDevice        = nullptr;
static ID3D12CommandQueue*        gCommandQueue  = nullptr; // captured from game — not our ref
static ID3D12DescriptorHeap*      gSrvHeap       = nullptr;
static ID3D12DescriptorHeap*      gRtvHeap       = nullptr;
static ID3D12GraphicsCommandList* gCmdList       = nullptr;
static HWND                       gWindow        = nullptr;
static bool                       gImGuiInitialized = false;

constexpr UINT kMaxFrames = 3;

struct FrameCtx {
    ID3D12CommandAllocator* allocator  = nullptr;
    ID3D12Resource*         backBuffer = nullptr;
    D3D12_CPU_DESCRIPTOR_HANDLE rtv{};
    ID3D12Fence*            fence      = nullptr;
    UINT64                  fenceValue = 0;
};

static FrameCtx gFrames[kMaxFrames]{};
static HANDLE   gFenceEvent = nullptr;
static UINT     gNumFrames  = 0;

namespace GH2 {
    bool     ConnectRenderQueue();
    void     DisconnectRenderQueue();
    uint32_t PopAll(RenderOp* outOps, uint32_t outCapacity);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void WaitFrame(UINT idx)
{
    FrameCtx& f = gFrames[idx];
    if (!f.fence || !gFenceEvent) return;
    if (f.fence->GetCompletedValue() < f.fenceValue) {
        f.fence->SetEventOnCompletion(f.fenceValue, gFenceEvent);
        WaitForSingleObject(gFenceEvent, INFINITE);
    }
}

static void SignalFrame(UINT idx)
{
    FrameCtx& f = gFrames[idx];
    if (!f.fence || !gCommandQueue) return;
    ++f.fenceValue;
    gCommandQueue->Signal(f.fence, f.fenceValue);
}

static void ReleaseBackBuffers()
{
    for (UINT i = 0; i < kMaxFrames; ++i) {
        if (gFrames[i].backBuffer) { gFrames[i].backBuffer->Release(); gFrames[i].backBuffer = nullptr; }
    }
}

static bool RebuildRTVs(IDXGISwapChain3* swap3, UINT numFrames)
{
    UINT stride = gDevice->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE handle = gRtvHeap->GetCPUDescriptorHandleForHeapStart();

    for (UINT i = 0; i < numFrames; ++i) {
        if (FAILED(swap3->GetBuffer(i, IID_PPV_ARGS(&gFrames[i].backBuffer)))) return false;
        gDevice->CreateRenderTargetView(gFrames[i].backBuffer, nullptr, handle);
        gFrames[i].rtv = handle;
        handle.ptr += stride;
    }
    return true;
}

static void ShutdownOverlay()
{
    if (!gDevice) return;

    for (UINT i = 0; i < kMaxFrames; ++i) WaitFrame(i);

    GH2::DisconnectRenderQueue();

    if (gImGuiInitialized) {
        ImGui_ImplDX12_Shutdown();
        ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
        gImGuiInitialized = false;
    }

    for (UINT i = 0; i < kMaxFrames; ++i) {
        if (gFrames[i].backBuffer) { gFrames[i].backBuffer->Release(); gFrames[i].backBuffer = nullptr; }
        if (gFrames[i].allocator)  { gFrames[i].allocator->Release();  gFrames[i].allocator  = nullptr; }
        if (gFrames[i].fence)      { gFrames[i].fence->Release();      gFrames[i].fence      = nullptr; }
    }
    if (gCmdList)  { gCmdList->Release();  gCmdList  = nullptr; }
    if (gRtvHeap)  { gRtvHeap->Release();  gRtvHeap  = nullptr; }
    if (gSrvHeap)  { gSrvHeap->Release();  gSrvHeap  = nullptr; }
    if (gFenceEvent) { CloseHandle(gFenceEvent); gFenceEvent = nullptr; }
    if (gDevice)   { gDevice->Release();   gDevice   = nullptr; }
    gCommandQueue = nullptr;
}

// ---------------------------------------------------------------------------
// Init ImGui (called first time hkPresent fires after command queue is known)
// ---------------------------------------------------------------------------

static bool InitImGui(IDXGISwapChain* swap)
{
    if (!gCommandQueue) return false;

    IDXGISwapChain3* swap3 = nullptr;
    if (FAILED(swap->QueryInterface(IID_PPV_ARGS(&swap3)))) return false;

    DXGI_SWAP_CHAIN_DESC sd{};
    swap3->GetDesc(&sd);
    gWindow    = sd.OutputWindow;
    gNumFrames = sd.BufferCount < kMaxFrames ? sd.BufferCount : kMaxFrames;

    if (FAILED(gCommandQueue->GetDevice(IID_PPV_ARGS(&gDevice)))) goto fail;

    // SRV heap for ImGui font atlas (shader visible, 1 descriptor)
    {
        D3D12_DESCRIPTOR_HEAP_DESC d{};
        d.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        d.NumDescriptors = 1;
        d.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        if (FAILED(gDevice->CreateDescriptorHeap(&d, IID_PPV_ARGS(&gSrvHeap)))) goto fail;
    }

    // RTV heap (one entry per back buffer)
    {
        D3D12_DESCRIPTOR_HEAP_DESC d{};
        d.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        d.NumDescriptors = gNumFrames;
        d.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        if (FAILED(gDevice->CreateDescriptorHeap(&d, IID_PPV_ARGS(&gRtvHeap)))) goto fail;
    }

    // Per-frame: command allocator + fence
    gFenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!gFenceEvent) goto fail;

    for (UINT i = 0; i < gNumFrames; ++i) {
        if (FAILED(gDevice->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&gFrames[i].allocator)))) goto fail;
        if (FAILED(gDevice->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gFrames[i].fence)))) goto fail;
    }

    if (!RebuildRTVs(swap3, gNumFrames)) goto fail;

    // Shared command list (reset per frame against the right allocator)
    if (FAILED(gDevice->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
        gFrames[0].allocator, nullptr, IID_PPV_ARGS(&gCmdList)))) goto fail;
    gCmdList->Close();

    // ImGui
    ImGui::CreateContext();
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    if (!ImGui_ImplWin32_Init(gWindow)) goto fail;
    if (!ImGui_ImplDX12_Init(gDevice, (int)gNumFrames, DXGI_FORMAT_R8G8B8A8_UNORM,
        gSrvHeap,
        gSrvHeap->GetCPUDescriptorHandleForHeapStart(),
        gSrvHeap->GetGPUDescriptorHandleForHeapStart())) goto fail;

    swap3->Release();
    gImGuiInitialized = GH2::ConnectRenderQueue();
    return gImGuiInitialized;

fail:
    swap3->Release();
    ShutdownOverlay();
    return false;
}

// ---------------------------------------------------------------------------
// Draw ops from the shared render queue
// ---------------------------------------------------------------------------

static void DrawFromQueue()
{
    GH2::RenderOp ops[256]{};
    uint32_t count = GH2::PopAll(ops, 256);
    if (!count) return;

    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    for (uint32_t i = 0; i < count; ++i) {
        const auto& op = ops[i];
        switch (op.type) {
        case GH2::RenderOpType::Rect:
            dl->AddRect(ImVec2(op.x, op.y), ImVec2(op.x + op.w, op.y + op.h), op.color);
            break;
        case GH2::RenderOpType::FilledRect:
            dl->AddRectFilled(ImVec2(op.x, op.y), ImVec2(op.x + op.w, op.y + op.h), op.color);
            break;
        case GH2::RenderOpType::HealthBar:
            dl->AddRectFilled(ImVec2(op.x, op.y), ImVec2(op.x + op.w * op.value, op.y + op.h), op.color);
            break;
        case GH2::RenderOpType::Text:
            dl->AddText(ImVec2(op.x, op.y), op.color, op.text);
            break;
        default:
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

void __stdcall hkExecCmdLists(ID3D12CommandQueue* queue, UINT numLists, ID3D12CommandList* const* lists)
{
    // Capture the first DIRECT queue we see — that's the render queue used with the swapchain.
    if (!gCommandQueue) {
        D3D12_COMMAND_QUEUE_DESC desc = queue->GetDesc();
        if (desc.Type == D3D12_COMMAND_LIST_TYPE_DIRECT)
            gCommandQueue = queue; // deliberately not AddRef — we never Release it
    }
    if (oExecCmdLists) oExecCmdLists(queue, numLists, lists);
}

HRESULT __stdcall hkResizeBuffers(IDXGISwapChain* swap, UINT bufferCount, UINT width, UINT height, DXGI_FORMAT format, UINT flags)
{
    if (gImGuiInitialized) {
        ImGui_ImplDX12_InvalidateDeviceObjects();
        ReleaseBackBuffers();
    }

    HRESULT hr = oResizeBuffers ? oResizeBuffers(swap, bufferCount, width, height, format, flags) : S_OK;

    if (SUCCEEDED(hr) && gDevice) {
        IDXGISwapChain3* swap3 = nullptr;
        if (SUCCEEDED(swap->QueryInterface(IID_PPV_ARGS(&swap3)))) {
            gNumFrames = (bufferCount > 0 && bufferCount <= kMaxFrames) ? bufferCount : gNumFrames;
            RebuildRTVs(swap3, gNumFrames);
            swap3->Release();
        }
        if (gImGuiInitialized) ImGui_ImplDX12_CreateDeviceObjects();
    }

    return hr;
}

HRESULT __stdcall hkPresent(IDXGISwapChain* swap, UINT syncInterval, UINT flags)
{
    if (!gImGuiInitialized && !InitImGui(swap))
        return oPresent ? oPresent(swap, syncInterval, flags) : S_OK;

    IDXGISwapChain3* swap3 = nullptr;
    if (FAILED(swap->QueryInterface(IID_PPV_ARGS(&swap3))))
        return oPresent ? oPresent(swap, syncInterval, flags) : S_OK;

    const UINT frameIdx = swap3->GetCurrentBackBufferIndex() % gNumFrames;
    swap3->Release();

    WaitFrame(frameIdx);

    FrameCtx& frame = gFrames[frameIdx];
    frame.allocator->Reset();
    gCmdList->Reset(frame.allocator, nullptr);

    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Flags                  = D3D12_RESOURCE_BARRIER_FLAG_NONE;
    barrier.Transition.pResource   = frame.backBuffer;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    barrier.Transition.StateAfter  = D3D12_RESOURCE_STATE_RENDER_TARGET;
    gCmdList->ResourceBarrier(1, &barrier);

    gCmdList->OMSetRenderTargets(1, &frame.rtv, FALSE, nullptr);
    gCmdList->SetDescriptorHeaps(1, &gSrvHeap);

    ImGui_ImplDX12_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    DrawFromQueue();
    ImGui::Render();
    ImGui_ImplDX12_RenderDrawData(ImGui::GetDrawData(), gCmdList);

    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter  = D3D12_RESOURCE_STATE_PRESENT;
    gCmdList->ResourceBarrier(1, &barrier);

    gCmdList->Close();
    gCommandQueue->ExecuteCommandLists(1, reinterpret_cast<ID3D12CommandList**>(&gCmdList));
    SignalFrame(frameIdx);

    return oPresent ? oPresent(swap, syncInterval, flags) : S_OK;
}

// ---------------------------------------------------------------------------
// VTable bootstrap: create a temp DX12 device + swapchain to read addresses
// ---------------------------------------------------------------------------

static bool GetVTableMethods(void** present, void** resizeBuffers, void** execCmdLists)
{
    *present = *resizeBuffers = *execCmdLists = nullptr;

    ID3D12Device*       device   = nullptr;
    ID3D12CommandQueue* cmdQueue = nullptr;
    IDXGIFactory4*      factory  = nullptr;
    IDXGISwapChain1*    sc1      = nullptr;
    IDXGISwapChain3*    sc3      = nullptr;

    WNDCLASSEXW wc{ sizeof(WNDCLASSEXW), CS_CLASSDC, DefWindowProcW, 0, 0, GetModuleHandleW(nullptr) };
    wc.lpszClassName = L"GH2DX12Tmp";
    RegisterClassExW(&wc);
    HWND wnd = CreateWindowW(wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW, 0, 0, 100, 100,
        nullptr, nullptr, wc.hInstance, nullptr);

    bool ok = false;

    if (FAILED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)))) goto cleanup;

    {
        D3D12_COMMAND_QUEUE_DESC qd{};
        qd.Type  = D3D12_COMMAND_LIST_TYPE_DIRECT;
        qd.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
        if (FAILED(device->CreateCommandQueue(&qd, IID_PPV_ARGS(&cmdQueue)))) goto cleanup;
    }

    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) goto cleanup;

    {
        DXGI_SWAP_CHAIN_DESC1 scd{};
        scd.BufferCount  = 2;
        scd.Width        = scd.Height = 100;
        scd.Format       = DXGI_FORMAT_R8G8B8A8_UNORM;
        scd.BufferUsage  = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        scd.SwapEffect   = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        scd.SampleDesc.Count = 1;

        if (FAILED(factory->CreateSwapChainForHwnd(cmdQueue, wnd, &scd, nullptr, nullptr, &sc1))) goto cleanup;
        if (FAILED(sc1->QueryInterface(IID_PPV_ARGS(&sc3)))) goto cleanup;
    }

    {
        void** scVtbl  = *reinterpret_cast<void***>(sc3);
        void** cqVtbl  = *reinterpret_cast<void***>(cmdQueue);
        *present        = scVtbl[8];   // IDXGISwapChain::Present
        *resizeBuffers  = scVtbl[13];  // IDXGISwapChain::ResizeBuffers
        *execCmdLists   = cqVtbl[10];  // ID3D12CommandQueue::ExecuteCommandLists
        ok = true;
    }

cleanup:
    if (sc3)      sc3->Release();
    if (sc1)      sc1->Release();
    if (factory)  factory->Release();
    if (cmdQueue) cmdQueue->Release();
    if (device)   device->Release();
    if (wnd)      DestroyWindow(wnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    return ok;
}

// ---------------------------------------------------------------------------
// DllMain
// ---------------------------------------------------------------------------

static DWORD WINAPI InstallHookThread(LPVOID)
{
    void* present = nullptr, *resizeBuffers = nullptr, *execCmdLists = nullptr;
    if (!GetVTableMethods(&present, &resizeBuffers, &execCmdLists)) return 0;

    if (MH_Initialize() != MH_OK) return 0;

    MH_CreateHook(present,       &hkPresent,       reinterpret_cast<void**>(&oPresent));
    MH_CreateHook(resizeBuffers, &hkResizeBuffers,  reinterpret_cast<void**>(&oResizeBuffers));
    MH_CreateHook(execCmdLists,  &hkExecCmdLists,   reinterpret_cast<void**>(&oExecCmdLists));
    MH_EnableHook(MH_ALL_HOOKS);
    return 0;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        HANDLE h = CreateThread(nullptr, 0, InstallHookThread, nullptr, 0, nullptr);
        if (h) CloseHandle(h);
    } else if (reason == DLL_PROCESS_DETACH) {
        MH_DisableHook(MH_ALL_HOOKS);
        MH_Uninitialize();
        ShutdownOverlay();
    }
    return TRUE;
}
