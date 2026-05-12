@echo off
setlocal

set ROOT=%~dp0
set DLL=%ROOT%build\Release\PoE2DX11Overlay.dll

if not exist "%DLL%" (
  echo ERROR: Build output missing: %DLL%
  exit /b 1
)

echo OK: Found overlay DLL -^> %DLL%
echo OK: MinHook is statically compiled into PoE2DX11Overlay.dll (no separate runtime MinHook DLL needed).
echo Next: inject PoE2DX11Overlay.dll into PoE2.exe process.
endlocal
