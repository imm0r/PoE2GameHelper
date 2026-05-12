param(
    [string]$Generator = "Visual Studio 17 2022",
    [string]$Arch = "x64",
    [string]$BuildType = "Release"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$imgui = Join-Path $root "third_party/imgui"
$minhook = Join-Path $root "third_party/minhook"

if (!(Test-Path $imgui)) { throw "ImGui not found: $imgui" }
if (!(Test-Path $minhook)) { throw "MinHook not found: $minhook" }

cmake -S $root -B (Join-Path $root "build") -G $Generator -A $Arch `
  -DIMGUI_DIR="$imgui" `
  -DMINHOOK_DIR="$minhook"
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }

cmake --build (Join-Path $root "build") --config $BuildType
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }

Write-Host "Build complete: $root/build/$BuildType/PoE2DX11Overlay.dll"
