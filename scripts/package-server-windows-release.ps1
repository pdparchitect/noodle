# Builds Noodle Server for Windows on the processor the installed Swift builds for, as dist/server-VERSION/
# Noodle-Server-windows-ARCH.zip: a Noodle Server folder holding noodled.exe with the msquic.dll devices reach it
# through, the Swift and Visual C++ runtimes it needs, the example configuration and the README; and the
# archive's checksum.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/windows-common.ps1"
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -Raw "$root/Server/VERSION").Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid Server/VERSION: $version" }
# Development hooks are never built into a release.
if ($env:NOODLE_DEV_HOOKS) { throw 'Unset NOODLE_DEV_HOOKS for a release build.' }

$build = @('build', '-c', 'release', '--package-path', "$root/Server",
           '--scratch-path', "$root/.build/server-windows-release", '--product', 'noodled') + $SwiftWindowsFlags
Invoke-Swift @build
$arch = Get-SwiftTargetArchitecture
$bin = (Invoke-Swift @build --show-bin-path | Select-Object -Last 1).Trim()

$stage = Join-Path ([IO.Path]::GetTempPath()) "noodle-server-$([guid]::NewGuid())"
$folder = New-Item -ItemType Directory (Join-Path $stage 'Noodle Server')
try {
    Copy-Item "$bin/noodled.exe" $folder
    Copy-WindowsRuntime -Folder $folder -Program noodled.exe -Architecture $arch
    & "$PSScriptRoot/fetch-msquic-windows.ps1" -Destination $folder -Architecture $arch
    Copy-Item "$root/Shared/HubLink/Sources/CNoodleQUIC/msquic/LICENSE" "$folder/msquic-LICENSE.txt"
    Copy-Item "$root/Server/noodled.yaml", "$root/Server/README.md" $folder
    $usage = & "$folder/noodled.exe" --help | Out-String
    if ($usage -notmatch 'USAGE: noodled') { throw 'The release binary did not start.' }

    $out = "$root/dist/server-$version"
    $archive = "Noodle-Server-windows-$arch.zip"
    New-Item -ItemType Directory -Force $out | Out-Null
    Write-ReleaseZip -Folder $folder -Archive "$out/$archive"
    Write-Output "Packed $out/$archive"
} finally {
    Remove-Item -Recurse -Force $stage
}
