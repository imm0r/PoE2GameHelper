# DX11 Overlay Build (Windows)

## 1) Voraussetzungen

- Visual Studio 2022 mit **Desktop development with C++**
- CMake >= 3.20
- Git

## 2) Dependencies holen

Im Ordner `dx11_overlay`:

```powershell
mkdir third_party
cd third_party
git clone https://github.com/ocornut/imgui.git
git clone https://github.com/TsudaKageyu/minhook.git
cd ..
```

## 3) Konfigurieren (PowerShell)

> Wichtig: In PowerShell ist der Zeilenumbruch **Backtick** ( `` ` `` ), nicht `\`.

**Einzeilig (empfohlen):**

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 -DIMGUI_DIR="$PWD/third_party/imgui" -DMINHOOK_DIR="$PWD/third_party/minhook"
```

**Mehrzeilig (PowerShell):**

```powershell
cmake -S . -B build -G "Visual Studio 17 2022" -A x64 `
  -DIMGUI_DIR="$PWD/third_party/imgui" `
  -DMINHOOK_DIR="$PWD/third_party/minhook"
```

## 4) Bauen

```powershell
cmake --build build --config Release
```

DLL liegt danach typischerweise unter:

- `build/Release/PoE2DX11Overlay.dll`

## 5) Hinweis zu MinHook

MinHook wird direkt in die Overlay-DLL einkompiliert.
Es ist **keine separate `minhook.dll`** zur Laufzeit nötig.

## Typische Fehler

- **`CommandNotFoundException` bei `-DIMGUI_DIR` / `-DMINHOOK_DIR`**
  - Ursache: Flags wurden in PowerShell als eigener Befehl eingegeben (meist wegen falschem Zeilenumbruch `\`).
  - Fix: kompletten `cmake` Befehl in **einer Zeile** ausführen oder PowerShell-Backticks verwenden.
- **Missing ImGui source ...** → `IMGUI_DIR` falsch.
- **cannot open include file imgui.h** → ImGui nicht geklont oder falscher Pfad.


## 6) Build verifizieren

```powershell
./verify_build.ps1
```

Das Skript prüft:
- ob `PoE2DX11Overlay.dll` gebaut wurde
- ob das Overlay-Build-Artifact vorhanden ist



## PowerShell ExecutionPolicy Problem

Wenn Skripte blockiert sind (`PSSecurityException`), nutze eine dieser Optionen:

1. Nur für diesen Aufruf:

```powershell
powershell -ExecutionPolicy Bypass -File .\verify_build.ps1
```

2. Ohne PowerShell-Skripte (CMD Fallback):

```cmd
verify_build.cmd
```



## Hinweis zu Skriptnamen

Es gibt jetzt zusätzlich ein `verify.ps1` als Kompatibilitäts-Wrapper auf `verify_build.ps1`.

