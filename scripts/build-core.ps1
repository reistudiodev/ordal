# Builds the Rust core, regenerates the Swift bindings and puts the static
# library where swift/Package.swift expects it. Windows.
#
#   .\scripts\build-core.ps1          # release build
#   .\scripts\build-core.ps1 -Debug   # debug build
param([switch]$Debug)
$ErrorActionPreference = "Stop"

$Root = Resolve-Path "$PSScriptRoot\.."
Set-Location $Root

$Profile = if ($Debug) { "debug" } else { "release" }
$CargoFlags = if ($Debug) { @() } else { @("--release") }

Write-Host "==> Building Rust core ($Profile)"
cargo build -p dbclient-core @CargoFlags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "==> Generating Swift bindings"
$Out = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid())
cargo run -q -p uniffi-bindgen -- generate `
  --library "target\$Profile\dbclient_core.dll" `
  --language swift `
  --out-dir $Out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$FfiDir = "swift\Sources\DBClientCoreFFI\include"
New-Item -ItemType Directory -Force $FfiDir | Out-Null
Copy-Item "$Out\DBClientCoreFFI.h" "$FfiDir\DBClientCoreFFI.h" -Force
# Drop the Apple-only `use` lines so the same module map works on Linux and Windows.
Get-Content "$Out\DBClientCoreFFI.modulemap" | Where-Object { $_ -notmatch '^\s*use "' } | Set-Content "$FfiDir\module.modulemap"
Copy-Item "$Out\DBClientCore.swift" "swift\Sources\DBClientCore\DBClientCore.swift" -Force
Remove-Item -Recurse -Force $Out

Write-Host "==> Copying static library to swift\lib"
Copy-Item "target\$Profile\dbclient_core.lib" "swift\lib\dbclient_core.lib" -Force

Write-Host "Done. Now: cd apps\windows; swift run"
