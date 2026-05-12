param(
    [string]$BuildType = "Release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dll = Join-Path $root "build/$BuildType/PoE2DX11Overlay.dll"

if (!(Test-Path $dll)) {
    throw "Build output missing: $dll"
}

Write-Host "OK: Found overlay DLL -> $dll"
Write-Host "OK: MinHook is statically compiled into PoE2DX11Overlay.dll (no separate runtime MinHook DLL needed)."
Write-Host "Next: inject PoE2DX11Overlay.dll into PoE2.exe process."
