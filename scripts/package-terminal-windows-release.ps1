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
    # Swift on Windows has no static runtime, so the DLLs noodle.exe loads, and those they load, go beside it,
    # and a computer needs no Swift installed.
    $runtime = Split-Path -Parent (Get-Command swiftCore.dll).Source
    $vs = & "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products * -property installationPath
    if (-not $vs) { throw 'Visual Studio was not found; its Visual C++ runtime goes in the ZIP.' }
    $crtArch = @{ arm64 = 'arm64'; x86_64 = 'x64' }[$arch]
    $crt = Get-ChildItem "$vs/VC/Redist/MSVC/*/$crtArch/Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
    if (-not $crt) { throw "Visual Studio at $vs has no Visual C++ runtime for $crtArch." }
    $system = [Environment]::GetFolderPath('System')
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue("$folder/noodle.exe")
    while ($pending.Count -gt 0) {
        $imports = & llvm-readobj --coff-imports $pending.Dequeue() | Select-String '^\s*Name: (.+\.dll)$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($name in $imports) {
            if (Test-Path "$folder/$name") { continue }
            $source = @("$runtime/$name", "$($crt.FullName)/$name") | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($source) {
                Copy-Item $source $folder
                $pending.Enqueue("$folder/$name")
            } elseif ($name -notlike 'api-ms-win-*' -and $name -notlike 'ext-ms-*' -and -not (Test-Path "$system/$name")) {
                # The check below runs where Swift and Visual Studio are installed, so it would not notice a
                # DLL left out here.
                throw "$name, which the program loads, is neither in Swift's or Visual C++'s runtime nor part of Windows."
            }
        }
    }
    & "$PSScriptRoot/fetch-msquic-windows.ps1" -Destination $folder -Architecture $arch
    Copy-Item "$root/Shared/HubLink/Sources/CNoodleQUIC/msquic/LICENSE" "$folder/msquic-LICENSE.txt"
    $usage = & "$folder/noodle.exe" --help | Out-String
    if ($usage -notmatch 'USAGE: noodle') { throw 'The release binary did not start.' }

    $out = "$root/dist/terminal-$version"
    $archive = "Noodle-Terminal-windows-$arch.zip"
    New-Item -ItemType Directory -Force $out | Out-Null
    Remove-Item -Force "$out/$archive" -ErrorAction SilentlyContinue
    # Entries are named with forward slashes, as every unzip expects; Windows PowerShell's Compress-Archive and
    # ZipFile write backslashes.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open("$out/$archive", [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem $folder -File -Recurse) {
            $entry = "$($folder.Name)/" + $file.FullName.Substring($folder.FullName.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entry,
                [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
    $hash = (Get-FileHash -Algorithm SHA256 "$out/$archive").Hash.ToLowerInvariant()
    # The checksum line sha256sum and shasum -c read, with Unix line endings.
    [IO.File]::WriteAllText("$out/$archive.sha256", "$hash  $archive`n")
    Write-Output "Packed $out/$archive"
} finally {
    Remove-Item -Recurse -Force $stage
}
