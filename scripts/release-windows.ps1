# Builds a Windows release: dist\Ordal-<version>-windows-x64.zip
# The zip holds Ordal.exe plus the DLLs it needs (Swift runtime and anything
# SwiftPM put next to the binary), so it runs without a Swift toolchain.
# Users still need the Windows App Runtime that WinUI depends on.
#
#   .\scripts\release-windows.ps1
#   .\scripts\release-windows.ps1 -Version 0.2.0
param([string]$Version)
$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
if (-not $Version) {
  $Version = (Select-String -Path "$Root\Cargo.toml" -Pattern '^version = "(.*)"').Matches[0].Groups[1].Value
}

& "$Root\scripts\build-core.ps1"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Set-Location "$Root\apps\windows"
swift build -c release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$Bin = (swift build -c release --show-bin-path).Trim()

$Name = "Ordal-$Version-windows-x64"
$Stage = "$Root\dist\$Name"
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force $Stage | Out-Null

Write-Host "==> Collecting files"
Copy-Item "$Bin\OrdalWindows.exe" "$Stage\Ordal.exe"
Get-ChildItem $Bin -Filter *.dll | Copy-Item -Destination $Stage
Get-ChildItem $Bin -Directory -Filter *.resources | Copy-Item -Destination $Stage -Recurse

# The Swift runtime DLLs live in the toolchain's runtime folder, which is on PATH.
$Runtime = Split-Path (Get-Command swiftCore.dll -ErrorAction Stop).Source
Get-ChildItem $Runtime -Filter *.dll | Copy-Item -Destination $Stage -Force

$Zip = "$Root\dist\$Name.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
Compress-Archive -Path "$Stage\*" -DestinationPath $Zip
Remove-Item -Recurse -Force $Stage
Write-Host "Built $Zip"
