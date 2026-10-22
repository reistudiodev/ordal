# Removes build caches and outputs: Rust target\, SwiftPM .build folders,
# the core library copied into swift\lib, and dist\. Leaves .env alone.
# Run .\scripts\build-core.ps1 again before building the apps.
$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
Set-Location $Root

Write-Host "==> Rust (target\)"
cargo clean
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Swift build caches"
$Caches = @("swift\.build", "swift\.swiftpm") + (Get-ChildItem apps -Directory | ForEach-Object { "$($_.FullName)\.build", "$($_.FullName)\.swiftpm" })
$Caches | Where-Object { Test-Path $_ } | Remove-Item -Recurse -Force

Write-Host "==> Copied core library (swift\lib)"
Get-ChildItem swift\lib -Include *.a, *.lib -Recurse | Remove-Item -Force

Write-Host "==> Release outputs (dist\)"
if (Test-Path dist) { Remove-Item -Recurse -Force dist }

Write-Host "Done. Rebuild with: .\scripts\build-core.ps1"
