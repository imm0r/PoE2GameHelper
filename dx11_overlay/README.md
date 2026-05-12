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
- `CMakeLists.txt` – Build-Definition inkl. ImGui-Quellen und Includes
- `build_windows.md` – Schritt-für-Schritt Build-Anleitung (VS/CMake)
- `inject_windows.md` – Inject- und Smoke-Test-Checkliste für den Live-Test
- `test_host/` – lokaler DX11-Testprozess als sichere Alternative
- `build_windows.ps1` – One-shot Build-Skript für PowerShell
- `verify_build.ps1` – prüft Build-Output und bestätigt statisch gelinktes MinHook
- `verify.ps1` – Kompatibilitäts-Wrapper (ruft `verify_build.ps1` auf)
- `verify_build.cmd` – gleiche Prüfung ohne PowerShell ExecutionPolicy-Abhängigkeit

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

`InstallHookThread` erzeugt eine temporäre D3D11-SwapChain, liest daraus die VTable-Adressen (`Present` Index 8, `ResizeBuffers` Index 13) und installiert beide Detours via statisch gelinktem MinHook.


## Build

Siehe `build_windows.md` für die manuelle Anleitung oder nutze `build_windows.ps1` für einen One-shot Build inklusive `-D` Pfaden.


## Injection

Für den ersten Live-Test siehe `inject_windows.md` (Reihenfolge, Smoke-Test, Troubleshooting).


## Safe Local Testing

Nutze `test_host/` um Hook/Queue/Renderpfad in einem eigenen lokalen Prozess zu testen, bevor du Live-Targets verwendest.


## AHK Producer Rolle

Der AHK Producer ist die **Daten-/Logik-Schicht**:

- Memory-Reads
- WorldToScreen
- Entity-Filter
- Erzeugung von `RenderOp` Einträgen

Empfohlener Startpunkt: `AHKProducerExample.ahk` (smoke-test + Grundstruktur).


## AHK Bridge Fehlerdiagnose

`RenderQueueBridge.ahk` gibt bei Init-Fehlern jetzt Windows-Fehlercodes aus (`WinErr=...`), um Mapping/Mutex-Probleme schneller zu finden.


Hinweis: Bei `WinErr=123` im AHK Bridge Init sind Mapping/Mutex-Namen häufig mit falschem String-Typ übergeben; die Bridge nutzt jetzt `wstr` für die `...W` APIs.


Hinweis: AHK-Strings verwenden **kein C-Style Backslash-Escaping**. Für Named Objects muss `Local\Name` (ein einzelner Backslash im String) verwendet werden, nicht `Local\\Name`.
