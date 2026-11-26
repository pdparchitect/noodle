# Builds Noodle Terminal for Windows on this machine's processor, as dist/terminal-VERSION/
# Noodle-Terminal-windows-ARCH.zip holding noodle.exe with the msquic.dll it talks to its Hub through and
# the Swift and Visual C++ runtimes it needs, and the archive's checksum.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$version = (Get-Content -Raw "$root/Terminal/VERSION").Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid Terminal/VERSION: $version" }
$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'ARM64' { 'arm64' }
    'AMD64' { 'x86_64' }
    default { throw 'Noodle Terminal is built for arm64 and x86_64 only.' }
}
# Development hooks are never built into a release.
if ($env:NOODLE_DEV_HOOKS) { throw 'Unset NOODLE_DEV_HOOKS for a release build.' }

# Microsoft's msquic built with OpenSSL, which reads the PEM certificates the link pins; Schannel's cannot.
$msquicVersion = '2.6.4'
$msquicSha256 = '370BAF73845AC516A7ACB53394EBF889CA947F7826A0E74F8F8C332B3627ADB5'
$package = Join-Path ([IO.Path]::GetTempPath()) "msquic-openssl-$msquicVersion.zip"
Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Native.Quic.MsQuic.OpenSSL/$msquicVersion" -OutFile $package
if ((Get-FileHash -Algorithm SHA256 $package).Hash -ne $msquicSha256) { throw 'msquic package checksum mismatch.' }
$msquic = Join-Path ([IO.Path]::GetTempPath()) "msquic-openssl-$msquicVersion"
Remove-Item -Recurse -Force $msquic -ErrorAction SilentlyContinue
Expand-Archive $package $msquic
$msquicArch = @{ arm64 = 'arm64'; x86_64 = 'x64' }[$arch]

$build = @('build', '--build-system', 'native', '-c', 'release', '--package-path', "$root/Terminal",
           '--scratch-path', "$root/.build/terminal-windows-release", '--product', 'noodle',
           # Visual Studio 2026's C++ library asks for a newer Clang than Swift 6.4 has, though it builds with it.
           '-Xcc', '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH', '-Xcxx', '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH')
# Swift's warnings on standard error are not failures; its exit code says whether it built.
function Invoke-Swift {
    $ErrorActionPreference = 'Continue'
    & swift @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "swift $($args -join ' ') failed." }
}
Invoke-Swift @build
$bin = (Invoke-Swift @build --show-bin-path | Select-Object -Last 1).Trim()

$stage = Join-Path ([IO.Path]::GetTempPath()) "noodle-terminal-$([guid]::NewGuid())"
$folder = New-Item -ItemType Directory (Join-Path $stage 'Noodle Terminal')
try {
    Copy-Item "$bin/noodle.exe" $folder
    # Swift on Windows has no static runtime, so the DLLs noodle.exe loads, and those they load, go beside it,
    # and a computer needs no Swift installed.
    $runtime = Split-Path -Parent (Get-Command swiftCore.dll).Source
    $vs = & "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products * -property installationPath
    $crtArch = @{ arm64 = 'arm64'; x86_64 = 'x64' }[$arch]
    $crt = Get-ChildItem "$vs/VC/Redist/MSVC/*/$crtArch/Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
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
            }
        }
    }
    Copy-Item "$msquic/build/native/bin/$msquicArch/msquic.dll" $folder
    Copy-Item "$root/Shared/HubLink/Sources/CNoodleQUIC/msquic/LICENSE" "$folder/msquic-LICENSE.txt"
    $usage = & "$folder/noodle.exe" --help | Out-String
    if ($usage -notmatch 'USAGE: noodle') { throw 'The release binary did not start.' }

    $out = "$root/dist/terminal-$version"
    $archive = "Noodle-Terminal-windows-$arch.zip"
    New-Item -ItemType Directory -Force $out | Out-Null
    Remove-Item -Force "$out/$archive" -ErrorAction SilentlyContinue
    Compress-Archive -Path $folder -DestinationPath "$out/$archive"
    $hash = (Get-FileHash -Algorithm SHA256 "$out/$archive").Hash.ToLowerInvariant()
    # The checksum line sha256sum and shasum -c read, with Unix line endings.
    [IO.File]::WriteAllText("$out/$archive.sha256", "$hash  $archive`n")
    Write-Output "Packed $out/$archive"
} finally {
    Remove-Item -Recurse -Force $stage
}
