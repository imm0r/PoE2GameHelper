# DX12 Overlay Hook

Dieses Modul bildet die native GPU-Render-Schicht für ein echtes In-Game Overlay in PoE2 (D3D12).

## Status

Aktuell implementiert:

- `hkPresent` Renderpfad (ImGui DX12 Backend + D3D12 Backbuffer)
- `hkResizeBuffers` Callback für RTV-Recreate bei SwapChain-Resize
- `hkExecCmdLists` Hook auf `ID3D12CommandQueue::ExecuteCommandLists` — capturt die echte Game-CommandQueue
- Fence-Synchronisation pro Frame (kein Allocator-Konflikt mit GPU)
- Shared-Memory `RenderQueue` Bridge zwischen AHK/Reader und DX12-DLL
- Draw-Ops: `Rect`, `FilledRect`, `Text`, `HealthBar`
- Ressourcen-Lifecycle (Init/Shutdown mit GPU-Wait)

Noch offen:

1. Font-Atlas / DPI-Scaling anpassen (ImGui Default-Font reicht für Testing)
2. Layering-Konzept (z.B. Vordergrund-DrawList für HUD, Hintergrund für Radar)

## Warum DX12 und nicht DX11?

PoE2 rendert mit Direct3D 12. Ein DX11-Hook erzeugt eine temporäre D3D11-SwapChain und hookt deren `Present` —
das landet aber in einem anderen VTable-Slot oder trifft den falschen Dispatch-Pfad. Der entscheidende Punkt:
`swap->GetDevice(__uuidof(ID3D11Device), ...)` schlägt in hkPresent fehl, weil das Spiel kein D3D11-Device hat →
ImGui wird nie initialisiert.

Der DX12-Hook:
1. Erstellt ein temporäres D3D12-Device + SwapChain → liest VTable-Adressen (gleiche Slots: Present=8, ResizeBuffers=13)
2. Hookt zusätzlich `ID3D12CommandQueue::ExecuteCommandLists` (VTable[10]) → capturt die Game-CommandQueue
3. Initialisiert ImGui mit `ImGui_ImplDX12_Init` sobald Queue bekannt ist

## Dateien

- `DX12OverlayHook.cpp` – Present/Resize/ExecCmdLists Hooks, DX12 ImGui Init, Fence-Sync, RenderQueue
- `DX11OverlayHook.cpp` – Alter DX11-Hook (nur als Referenz, nicht mehr gebaut)
- `RenderQueueShared.h` – gemeinsames Datenmodell für Queue-IPC
- `RenderQueueClient.cpp` – Queue-Reader (DLL-Seite)
- `RenderQueueBridge.ahk` – Queue-Producer (AHK-Seite)
- `CMakeLists.txt` – Build-Definition: `PoE2DX12Overlay` DLL + `DX12OverlayTestHost` EXE
- `build_windows.md` – Schritt-für-Schritt Build-Anleitung (VS/CMake)
- `inject_windows.md` – Inject- und Smoke-Test-Checkliste für den Live-Test
- `test_host/DX12OverlayTestHost.cpp` – lokaler DX12-Testprozess (flip-model swapchain, clear + present loop)
- `build_windows.ps1` – One-shot Build-Skript für PowerShell
- `verify_build.ps1` – prüft Build-Output und bestätigt statisch gelinktes MinHook

## Hook-Reihenfolge

```
DLL_PROCESS_ATTACH
  └─ InstallHookThread
       └─ GetVTableMethods()         — temp D3D12 Device + SwapChain3 + CommandQueue
            ├─ MH_CreateHook(Present[8])         → hkPresent
            ├─ MH_CreateHook(ResizeBuffers[13])  → hkResizeBuffers
            └─ MH_CreateHook(ExecCmdLists[10])   → hkExecCmdLists

Game läuft:
  hkExecCmdLists  → gCommandQueue = queue (erster DIRECT-Queue)
  hkPresent       → InitImGui() mit gCommandQueue → ImGui_ImplDX12_Init
  hkPresent       → DrawFromQueue() → ImGui_ImplDX12_RenderDrawData
```

## Queue/IPC Modell

- FileMapping: `Local\PoE2GH_RenderQueue_v1`
- Mutex: `Local\PoE2GH_RenderQueueMutex_v1`
- Ringbuffer mit fester Kapazität (`2048` Ops, `RenderOp` = 124 Byte)
- Producer (AHK/Bridge) schreibt Ops; Consumer (DX12-Hook) leert Queue pro Frame

## AHK Producer Beispiel

```ahk
bridge := GH2RenderQueueBridge()
bridge.PushHealthBar(400, 200, 160, 10, 0.72, 0xFF00FF00)
bridge.PushText(400, 185, "Rare Monster", 0xFFFFFFFF)
```

## Ziel-Pipeline

`AHK (Memory/W2S/Entity) → Shared RenderQueue → hkPresent → ImGui DX12 DrawData → D3D12 Backbuffer`

## Build

```powershell
# Abhängigkeiten in third_party/ ablegen:
#   third_party/imgui/       — dear imgui (mit backends/)
#   third_party/minhook/     — MinHook (src/ + include/)

cmake -S dx11_overlay -B build/dx12overlay -DCMAKE_BUILD_TYPE=Release
cmake --build build/dx12overlay --config Release
# Output: build/dx12overlay/Release/PoE2DX12Overlay.dll
#         build/dx12overlay/Release/DX12OverlayTestHost.exe
```

Oder `build_windows.ps1` nutzen (setzt IMGUI_DIR/MINHOOK_DIR automatisch).

## Safe Local Testing

```
1. DX12OverlayTestHost.exe starten
2. PoE2DX12Overlay.dll injizieren (z.B. Process Hacker → Inject DLL)
3. AHKProducerExample.ahk starten → Ops werden im Testfenster sichtbar
```

## AHK Bridge Fehlerdiagnose

`RenderQueueBridge.ahk` gibt bei Init-Fehlern Windows-Fehlercodes aus (`WinErr=...`).

Hinweis: AHK-Strings verwenden **kein C-Style Backslash-Escaping**. Named Objects brauchen
`Local\Name` (ein Backslash), nicht `Local\\Name`.
