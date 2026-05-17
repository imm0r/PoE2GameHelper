// Standalone DX12 test host.
// Build with CMakeLists target DX12OverlayTestHost, then:
//   1. Run this exe
//   2. Inject PoE2DX12Overlay.dll with your injector of choice
//   3. Run the AHK producer to push RenderOps into the shared queue
#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>

#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")

using Microsoft::WRL::ComPtr;

static constexpr UINT kFrameCount = 2;

static ComPtr<ID3D12Device>              gDevice;
static ComPtr<ID3D12CommandQueue>        gCmdQueue;
static ComPtr<IDXGISwapChain3>           gSwapChain;
static ComPtr<ID3D12DescriptorHeap>      gRtvHeap;
static ComPtr<ID3D12CommandAllocator>    gCmdAlloc[kFrameCount];
static ComPtr<ID3D12GraphicsCommandList> gCmdList;
static ComPtr<ID3D12Resource>            gRenderTargets[kFrameCount];
static ComPtr<ID3D12Fence>               gFence;
static HANDLE                            gFenceEvent = nullptr;
static UINT64                            gFenceValues[kFrameCount]{};
static UINT                              gRtvStride = 0;

LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hWnd, msg, wParam, lParam);
}

static bool Init(HWND hwnd, UINT width, UINT height)
{
    ComPtr<IDXGIFactory4> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
    if (FAILED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&gDevice)))) return false;

    D3D12_COMMAND_QUEUE_DESC qd{};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (FAILED(gDevice->CreateCommandQueue(&qd, IID_PPV_ARGS(&gCmdQueue)))) return false;

    DXGI_SWAP_CHAIN_DESC1 scd{};
    scd.BufferCount  = kFrameCount;
    scd.Width        = width;
    scd.Height       = height;
    scd.Format       = DXGI_FORMAT_R8G8B8A8_UNORM;
    scd.BufferUsage  = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.SwapEffect   = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    scd.SampleDesc.Count = 1;

    ComPtr<IDXGISwapChain1> sc1;
    if (FAILED(factory->CreateSwapChainForHwnd(gCmdQueue.Get(), hwnd, &scd, nullptr, nullptr, &sc1))) return false;
    sc1.As(&gSwapChain);

    D3D12_DESCRIPTOR_HEAP_DESC rtvDesc{};
    rtvDesc.Type           = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    rtvDesc.NumDescriptors = kFrameCount;
    rtvDesc.Flags          = D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    if (FAILED(gDevice->CreateDescriptorHeap(&rtvDesc, IID_PPV_ARGS(&gRtvHeap)))) return false;

    gRtvStride = gDevice->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE rtvHandle = gRtvHeap->GetCPUDescriptorHandleForHeapStart();

    for (UINT i = 0; i < kFrameCount; ++i) {
        if (FAILED(gSwapChain->GetBuffer(i, IID_PPV_ARGS(&gRenderTargets[i])))) return false;
        gDevice->CreateRenderTargetView(gRenderTargets[i].Get(), nullptr, rtvHandle);
        rtvHandle.ptr += gRtvStride;
        if (FAILED(gDevice->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&gCmdAlloc[i])))) return false;
    }

    if (FAILED(gDevice->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
        gCmdAlloc[0].Get(), nullptr, IID_PPV_ARGS(&gCmdList)))) return false;
    gCmdList->Close();

    if (FAILED(gDevice->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&gFence)))) return false;
    gFenceEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    return gFenceEvent != nullptr;
}

static void WaitForFrame(UINT frameIdx)
{
    if (gFence->GetCompletedValue() < gFenceValues[frameIdx]) {
        gFence->SetEventOnCompletion(gFenceValues[frameIdx], gFenceEvent);
        WaitForSingleObject(gFenceEvent, INFINITE);
    }
}

static void Render()
{
    const UINT frameIdx = gSwapChain->GetCurrentBackBufferIndex();
    WaitForFrame(frameIdx);

    gCmdAlloc[frameIdx]->Reset();
    gCmdList->Reset(gCmdAlloc[frameIdx].Get(), nullptr);

    // Transition to render target
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type                   = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource   = gRenderTargets[frameIdx].Get();
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
    barrier.Transition.StateAfter  = D3D12_RESOURCE_STATE_RENDER_TARGET;
    gCmdList->ResourceBarrier(1, &barrier);

    D3D12_CPU_DESCRIPTOR_HANDLE rtv = gRtvHeap->GetCPUDescriptorHandleForHeapStart();
    rtv.ptr += (SIZE_T)frameIdx * gRtvStride;
    const float clearColor[] = { 0.05f, 0.05f, 0.10f, 1.0f };
    gCmdList->ClearRenderTargetView(rtv, clearColor, 0, nullptr);
    gCmdList->OMSetRenderTargets(1, &rtv, FALSE, nullptr);

    // Transition back to present
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
    barrier.Transition.StateAfter  = D3D12_RESOURCE_STATE_PRESENT;
    gCmdList->ResourceBarrier(1, &barrier);

    gCmdList->Close();
    gCmdQueue->ExecuteCommandLists(1, reinterpret_cast<ID3D12CommandList**>(gCmdList.GetAddressOf()));

    gSwapChain->Present(1, 0);

    ++gFenceValues[frameIdx];
    gCmdQueue->Signal(gFence.Get(), gFenceValues[frameIdx]);
}

static void Cleanup()
{
    for (UINT i = 0; i < kFrameCount; ++i) WaitForFrame(i);
    if (gFenceEvent) CloseHandle(gFenceEvent);
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE, LPSTR, int)
{
    WNDCLASSEXW wc{ sizeof(WNDCLASSEXW), CS_CLASSDC, WndProc, 0, 0, hInstance };
    wc.lpszClassName = L"DX12OverlayTestHost";
    RegisterClassExW(&wc);

    constexpr UINT kW = 1280, kH = 720;
    HWND hwnd = CreateWindowW(wc.lpszClassName, L"DX12 Overlay Test Host",
        WS_OVERLAPPEDWINDOW, 100, 100, kW, kH, nullptr, nullptr, hInstance, nullptr);

    if (!Init(hwnd, kW, kH)) {
        MessageBoxW(nullptr, L"DX12 init failed", L"Error", MB_OK | MB_ICONERROR);
        return 1;
    }

    ShowWindow(hwnd, SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    MSG msg{};
    while (msg.message != WM_QUIT) {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Render();
    }

    Cleanup();
    DestroyWindow(hwnd);
    UnregisterClassW(wc.lpszClassName, hInstance);
    return 0;
}
