# Builds Noodle Terminal for Windows on the processor the installed Swift builds for, as dist/terminal-VERSION/
# Noodle-Terminal-windows-ARCH.zip holding noodle.exe with the msquic.dll it talks to its Hub through and
# the Swift and Visual C++ runtimes it needs, and the archive's checksum.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/windows-common.ps1"
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -Raw "$root/Terminal/VERSION").Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid Terminal/VERSION: $version" }
# Development hooks are never built into a release.
if ($env:NOODLE_DEV_HOOKS) { throw 'Unset NOODLE_DEV_HOOKS for a release build.' }

$build = @('build', '-c', 'release', '--package-path', "$root/Terminal",
           '--scratch-path', "$root/.build/terminal-windows-release", '--product', 'noodle') + $SwiftWindowsFlags
Invoke-Swift @build
$arch = Get-SwiftTargetArchitecture
$bin = (Invoke-Swift @build --show-bin-path | Select-Object -Last 1).Trim()

$stage = Join-Path ([IO.Path]::GetTempPath()) "noodle-terminal-$([guid]::NewGuid())"
$folder = New-Item -ItemType Directory (Join-Path $stage 'Noodle Terminal')
try {
    Copy-Item "$bin/noodle.exe" $folder
    Copy-WindowsRuntime -Folder $folder -Program noodle.exe -Architecture $arch
    & "$PSScriptRoot/fetch-msquic-windows.ps1" -Destination $folder -Architecture $arch
    Copy-Item "$root/Shared/HubLink/Sources/CNoodleQUIC/msquic/LICENSE" "$folder/msquic-LICENSE.txt"
    $usage = & "$folder/noodle.exe" --help | Out-String
    if ($usage -notmatch 'USAGE: noodle') { throw 'The release binary did not start.' }

    $out = "$root/dist/terminal-$version"
    $archive = "Noodle-Terminal-windows-$arch.zip"
    New-Item -ItemType Directory -Force $out | Out-Null
    Write-ReleaseZip -Folder $folder -Archive "$out/$archive"
    Write-Output "Packed $out/$archive"
} finally {
    Remove-Item -Recurse -Force $stage
}
