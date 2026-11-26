# What the Windows scripts share, dot-sourced by each: the processor names the release uses, and the flags
# Swift builds with on Windows.

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
