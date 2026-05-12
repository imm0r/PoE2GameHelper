param([string]$BuildType = "Release")
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $root "verify_build.ps1") -BuildType $BuildType
exit $LASTEXITCODE
