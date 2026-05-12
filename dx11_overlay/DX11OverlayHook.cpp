#include <Windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include "imgui.h"
#include "imgui_impl_dx11.h"
#include "imgui_impl_win32.h"
#include "RenderQueueShared.h"

#pragma comment(lib, "d3d11.lib")

using PresentFn = HRESULT(__stdcall*)(IDXGISwapChain*, UINT, UINT);
using ResizeBuffersFn = HRESULT(__stdcall*)(IDXGISwapChain*, UINT, UINT, UINT, DXGI_FORMAT, UINT);
using MHInitializeFn = int(*)();
using MHCreateHookFn = int(*)(LPVOID, LPVOID, LPVOID*);
using MHEnableHookFn = int(*)(LPVOID);
using MHUninitializeFn = int(*)();

static PresentFn oPresent = nullptr;
static ResizeBuffersFn oResizeBuffers = nullptr;
static ID3D11Device* gDevice = nullptr;
static ID3D11DeviceContext* gContext = nullptr;
static ID3D11RenderTargetView* gRTV = nullptr;
static HWND gWindow = nullptr;
static bool gImGuiInitialized = false;

namespace GH2 {
    bool ConnectRenderQueue();
    void DisconnectRenderQueue();
    uint32_t PopAll(RenderOp* outOps, uint32_t outCapacity);
}

static void ReleaseRTV() { if (gRTV) { gRTV->Release(); gRTV = nullptr; } }

static bool CreateRTV(IDXGISwapChain* swap)
{
    ID3D11Texture2D* backBuffer = nullptr;
    if (FAILED(swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**)&backBuffer))) return false;
    const auto hr = gDevice->CreateRenderTargetView(backBuffer, nullptr, &gRTV);
    backBuffer->Release();
    return SUCCEEDED(hr);
}

static bool InitImGui(IDXGISwapChain* swap)
{
    DXGI_SWAP_CHAIN_DESC sd{};
    if (FAILED(swap->GetDesc(&sd))) return false;
    if (FAILED(swap->GetDevice(__uuidof(ID3D11Device), (void**)&gDevice))) return false;

    gDevice->GetImmediateContext(&gContext);
    gWindow = sd.OutputWindow;
    if (!CreateRTV(swap)) return false;

    ImGui::CreateContext();
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
    if (!ImGui_ImplWin32_Init(gWindow) || !ImGui_ImplDX11_Init(gDevice, gContext)) return false;

    gImGuiInitialized = GH2::ConnectRenderQueue();
    return gImGuiInitialized;
}

static void ShutdownOverlay()
{
    GH2::DisconnectRenderQueue();
    if (gImGuiInitialized) {
        ImGui_ImplDX11_Shutdown();
        ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
    }
    gImGuiInitialized = false;
    ReleaseRTV();
    if (gContext) { gContext->Release(); gContext = nullptr; }
    if (gDevice) { gDevice->Release(); gDevice = nullptr; }
}

static void DrawFromQueue()
{
    GH2::RenderOp ops[256]{};
    uint32_t count = GH2::PopAll(ops, 256);
    if (!count) return;

    ImDrawList* dl = ImGui::GetBackgroundDrawList();
    for (uint32_t i = 0; i < count; ++i) {
        const auto& op = ops[i];
        switch (op.type) {
        case GH2::RenderOpType::Rect: dl->AddRect(ImVec2(op.x, op.y), ImVec2(op.x + op.w, op.y + op.h), op.color); break;
        case GH2::RenderOpType::FilledRect: dl->AddRectFilled(ImVec2(op.x, op.y), ImVec2(op.x + op.w, op.y + op.h), op.color); break;
        case GH2::RenderOpType::HealthBar: dl->AddRectFilled(ImVec2(op.x, op.y), ImVec2(op.x + op.w * op.value, op.y + op.h), op.color); break;
        case GH2::RenderOpType::Text: dl->AddText(ImVec2(op.x, op.y), op.color, op.text); break;
        default: break;
        }
    }
}

HRESULT __stdcall hkResizeBuffers(IDXGISwapChain* swap, UINT bufferCount, UINT width, UINT height, DXGI_FORMAT format, UINT flags)
{
    ReleaseRTV();
    HRESULT hr = oResizeBuffers ? oResizeBuffers(swap, bufferCount, width, height, format, flags) : S_OK;
    if (SUCCEEDED(hr) && gDevice) CreateRTV(swap);
    return hr;
}

HRESULT __stdcall hkPresent(IDXGISwapChain* swap, UINT syncInterval, UINT flags)
{
    if (!gImGuiInitialized && !InitImGui(swap)) return oPresent ? oPresent(swap, syncInterval, flags) : S_OK;
    if (!gRTV && !CreateRTV(swap)) return oPresent ? oPresent(swap, syncInterval, flags) : S_OK;

    gContext->OMSetRenderTargets(1, &gRTV, nullptr);
    ImGui_ImplDX11_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    DrawFromQueue();
    ImGui::Render();
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
    return oPresent ? oPresent(swap, syncInterval, flags) : S_OK;
}

static bool GetSwapchainMethods(void** present, void** resizeBuffers)
{
    *present = nullptr;
    *resizeBuffers = nullptr;
    WNDCLASSEXW wc{ sizeof(WNDCLASSEXW), CS_CLASSDC, DefWindowProcW, 0, 0, GetModuleHandleW(nullptr), nullptr, nullptr, nullptr, nullptr, L"GH2DX11Tmp", nullptr };
    if (!RegisterClassExW(&wc)) return false;
    HWND wnd = CreateWindowW(wc.lpszClassName, L"", WS_OVERLAPPEDWINDOW, 0, 0, 100, 100, nullptr, nullptr, wc.hInstance, nullptr);
    if (!wnd) {
        UnregisterClassW(wc.lpszClassName, wc.hInstance);
        return false;
    }

    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 1; sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = wnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    ID3D11Device* dev = nullptr; ID3D11DeviceContext* ctx = nullptr; IDXGISwapChain* sc = nullptr;
    bool ok = SUCCEEDED(D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
        D3D11_SDK_VERSION, &sd, &sc, &dev, nullptr, &ctx));

    if (ok) {
        auto** vtbl = *reinterpret_cast<void***>(sc);
        *present = vtbl[8];
        *resizeBuffers = vtbl[13];
    }

    if (sc) sc->Release();
    if (ctx) ctx->Release();
    if (dev) dev->Release();
    DestroyWindow(wnd);
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    return ok;
}

static DWORD WINAPI InstallHookThread(LPVOID)
{
    HMODULE mh = LoadLibraryW(L"minhook.x64.dll");
    if (!mh) mh = LoadLibraryW(L"minhook.dll");
    if (!mh) return 0;

    auto MH_Initialize = reinterpret_cast<MHInitializeFn>(GetProcAddress(mh, "MH_Initialize"));
    auto MH_CreateHook = reinterpret_cast<MHCreateHookFn>(GetProcAddress(mh, "MH_CreateHook"));
    auto MH_EnableHook = reinterpret_cast<MHEnableHookFn>(GetProcAddress(mh, "MH_EnableHook"));
    auto MH_Uninitialize = reinterpret_cast<MHUninitializeFn>(GetProcAddress(mh, "MH_Uninitialize"));
    if (!MH_Initialize || !MH_CreateHook || !MH_EnableHook || !MH_Uninitialize) return 0;

    void* present = nullptr;
    void* resizeBuffers = nullptr;
    if (!GetSwapchainMethods(&present, &resizeBuffers)) return 0;

    if (MH_Initialize() != 0) return 0;
    if (MH_CreateHook(present, &hkPresent, reinterpret_cast<void**>(&oPresent)) != 0) return 0;
    if (MH_CreateHook(resizeBuffers, &hkResizeBuffers, reinterpret_cast<void**>(&oResizeBuffers)) != 0) return 0;
    if (MH_EnableHook(present) != 0 || MH_EnableHook(resizeBuffers) != 0) {
        MH_Uninitialize();
        return 0;
    }
    return 0;
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        HANDLE h = CreateThread(nullptr, 0, InstallHookThread, nullptr, 0, nullptr);
        if (h) CloseHandle(h);
    } else if (reason == DLL_PROCESS_DETACH) {
        ShutdownOverlay();
    }
    return TRUE;
}
