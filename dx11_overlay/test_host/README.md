# DX11 Overlay Test Host (Safe Local Test)

Dieses Testprogramm ist eine sichere lokale Alternative, um den DX11 `Present`-Hook zu validieren,
ohne in Drittanbieter-Spiele zu injizieren.

## Build

```powershell
cd dx11_overlay/test_host
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

## Ablauf

1. `DX11OverlayTestHost.exe` starten.
2. Overlay-DLL nur in diesen Testprozess laden (eigener Prozess).
3. AHK Producer starten und feste `PushText`/`PushHealthBar` Ops senden.
4. Prüfen, ob Hook + Queue + ImGui Rendering sichtbar arbeiten.

## Ziel

- Validierung von Hook-Installation
- Validierung von Shared Queue Transfer
- Validierung von Draw-Path (`Present`)
