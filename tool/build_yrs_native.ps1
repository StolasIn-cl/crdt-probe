# tool/build_yrs_native.ps1
#
# Builds yrs.dll from the vendored y-crdt source under native/yrs-src/ and
# copies it over native/yffi/v0.27.3/yrs.dll. Fully offline (--offline) --
# run tool/build_yrs_native.ps1 only when you've changed something under
# native/yrs-src/ and want a fresh yrs.dll; ordinary `flutter test`/
# `flutter build windows` never invoke this automatically.
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$srcDir = Join-Path $repoRoot "native\yrs-src"
$outDll = Join-Path $repoRoot "native\yffi\v0.27.3\yrs.dll"
$builtDll = Join-Path $srcDir "target\x86_64-pc-windows-msvc\release\yrs.dll"

if (-not (Test-Path $srcDir)) {
    throw "Vendored source not found at $srcDir -- see native/yrs-src/PROVENANCE.md"
}

Write-Host "Building yffi (release, offline) from $srcDir ..."
Push-Location $srcDir
try {
    cargo build -p yffi --release --target x86_64-pc-windows-msvc --offline
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

if (-not (Test-Path $builtDll)) {
    throw "Expected build output not found at $builtDll"
}

Copy-Item -Path $builtDll -Destination $outDll -Force
$hash = (Get-FileHash -Path $outDll -Algorithm SHA256).Hash
Write-Host ""
Write-Host "Copied $builtDll"
Write-Host "    -> $outDll"
Write-Host ""
Write-Host "SHA-256: $hash"
Write-Host "(paste this into native/yffi/v0.27.3/README.md)"
