# What the Windows scripts share, dot-sourced by each: the processor names the release uses, the flags
# Swift builds with on Windows, how Swift is run, and how a release folder is filled and zipped.

# The machine's processor, not this process's: an x64 PowerShell emulated on Windows on Arm still says arm64.
function Get-MachineArchitecture {
    switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'Arm64' { 'arm64' }
        'X64' { 'x86_64' }
        default { throw 'Noodle Terminal is built for arm64 and x86_64 only.' }
    }
}

# The processor the installed Swift builds for, so what is packed is named after what was built.
function Get-SwiftTargetArchitecture {
    $triple = (& swift -print-target-info | ConvertFrom-Json).target.triple
    switch -Wildcard ($triple) {
        'aarch64-*' { 'arm64' }
        'x86_64-*' { 'x86_64' }
        default { throw "Noodle Terminal is built for arm64 and x86_64 only, not $triple." }
    }
}

# Visual Studio 2026's C++ library asks for a newer Clang than Swift 6.4 has, though it builds with it.
$SwiftWindowsFlags = @('-Xcc', '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH', '-Xcxx', '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH')

# Runs swift, passing its output on as text. Its warnings on standard error are not failures; its exit code
# says whether it built and passed.
function Invoke-Swift {
    $ErrorActionPreference = 'Continue'
    & swift @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "swift $($args -join ' ') failed." }
}

# Copies into $Folder the DLLs the program there loads that Windows does not have, and those they load in turn:
# Swift on Windows has no static runtime, so its DLLs and Visual C++'s go beside the program, and a computer
# needs neither installed.
function Copy-WindowsRuntime {
    param([Parameter(Mandatory)] [string] $Folder, [Parameter(Mandatory)] [string] $Program,
          [Parameter(Mandatory)] [string] $Architecture)
    $runtime = Split-Path -Parent (Get-Command swiftCore.dll).Source
    $vs = & "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products * -property installationPath
    if (-not $vs) { throw 'Visual Studio was not found; its Visual C++ runtime goes in the ZIP.' }
    $crtArch = @{ arm64 = 'arm64'; x86_64 = 'x64' }[$Architecture]
    $crt = Get-ChildItem "$vs/VC/Redist/MSVC/*/$crtArch/Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
    if (-not $crt) { throw "Visual Studio at $vs has no Visual C++ runtime for $crtArch." }
    $system = [Environment]::GetFolderPath('System')
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue("$Folder/$Program")
    while ($pending.Count -gt 0) {
        $imports = & llvm-readobj --coff-imports $pending.Dequeue() | Select-String '^\s*Name: (.+\.dll)$' |
            ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($name in $imports) {
            if (Test-Path "$Folder/$name") { continue }
            $source = @("$runtime/$name", "$($crt.FullName)/$name") | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($source) {
                Copy-Item $source $Folder
                $pending.Enqueue("$Folder/$name")
            } elseif ($name -notlike 'api-ms-win-*' -and $name -notlike 'ext-ms-*' -and -not (Test-Path "$system/$name")) {
                # A check of the release runs where Swift and Visual Studio are installed, so it would not notice
                # a DLL left out here.
                throw "$name, which the program loads, is neither in Swift's or Visual C++'s runtime nor part of Windows."
            }
        }
    }
}

# Zips $Folder as $Archive, every entry under the folder's own name, and writes its checksum beside it.
function Write-ReleaseZip {
    param([Parameter(Mandatory)] [IO.DirectoryInfo] $Folder, [Parameter(Mandatory)] [string] $Archive)
    Remove-Item -Force $Archive -ErrorAction SilentlyContinue
    # Entries are named with forward slashes, as every unzip expects; Windows PowerShell's Compress-Archive and
    # ZipFile write backslashes.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem $Folder -File -Recurse) {
            $entry = "$($Folder.Name)/" + $file.FullName.Substring($Folder.FullName.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entry,
                [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }
    $hash = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
    # The checksum line sha256sum and shasum -c read, with Unix line endings.
    [IO.File]::WriteAllText("$Archive.sha256", "$hash  $(Split-Path -Leaf $Archive)`n")
}
