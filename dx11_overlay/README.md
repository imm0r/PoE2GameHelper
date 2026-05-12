# DX11 Overlay Hook

Dieses Modul bildet die native GPU-Render-Schicht für ein echtes In-Game Overlay in PoE2.

## Status

Aktuell implementiert:

- `hkPresent` Renderpfad (ImGui + D3D11 Backbuffer)
- `hkResizeBuffers` Callback für RTV-Recreate bei SwapChain-Resize
- Shared-Memory `RenderQueue` Bridge zwischen AHK/Reader und DX11-DLL
- Basale Draw-Ops: `Rect`, `FilledRect`, `Text`, `HealthBar`
- Ressourcen-Lifecycle (Init/Shutdown)

Noch offen:

1. MinHook-DLL Deployment sicherstellen (`minhook.x64.dll` oder `minhook.dll` im Suchpfad)
2. Optional: Font-Atlas + DPI-Scaling + Layering-Konzept

## Dateien

- `DX11OverlayHook.cpp` – Present/Resize Renderloop, Lifecycle und Hook-Bootstrap (MinHook)
- `RenderQueueShared.h` – gemeinsames Datenmodell für Queue-IPC
- `RenderQueueClient.cpp` – Queue-Reader (DLL-Seite)
- `RenderQueueBridge.ahk` – Queue-Producer (AHK-Seite)
- `CMakeLists.txt` – einfacher Build-Startpunkt für die DLL (Windows/MSVC)

## Queue/IPC Modell

- FileMapping: `Local\\PoE2GH_RenderQueue_v1`
- Mutex: `Local\\PoE2GH_RenderQueueMutex_v1`
- Ringbuffer mit fester Kapazität (`2048` Ops, `RenderOp` = 124 Byte)
- Producer (AHK/Bridge) schreibt Ops in Queue, Consumer (DX11-Hook) liest pro Frame und leert Queue

## AHK Producer Beispiel

```ahk
bridge := GH2RenderQueueBridge()
bridge.PushHealthBar(400, 200, 160, 10, 0.72, 0xFF00FF00)
bridge.PushText(400, 185, "Rare Monster", 0xFFFFFFFF)
```

## Ziel-Pipeline

`AHK (Memory/W2S/Entity) -> Shared RenderQueue -> DX11 Present Hook -> ImGui DrawData -> Backbuffer`


## Hook Bootstrap

`InstallHookThread` lädt MinHook dynamisch, erzeugt eine temporäre D3D11-SwapChain, liest daraus die VTable-Adressen (`Present` Index 8, `ResizeBuffers` Index 13) und installiert beide Detours.
