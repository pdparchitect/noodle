# Tests Noodle Server on Windows: the POSIX calls the Hub engine makes there, then the server, whose bots run in
# AppContainers and whose devices pair over msquic. The tests load msquic.dll from beside their runner, as
# noodled.exe does from beside itself.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/windows-common.ps1"
$root = Split-Path -Parent $PSScriptRoot

foreach ($package in @(@{ Path = 'Shared/WindowsPOSIX'; Scratch = 'windows-posix' }, @{ Path = 'Server'; Scratch = 'server-windows' })) {
    $options = @('--package-path', "$root/$($package.Path)", '--scratch-path', "$root/.build/$($package.Scratch)") + $SwiftWindowsFlags
    Invoke-Swift build --build-tests @options
    & "$PSScriptRoot/fetch-msquic-windows.ps1" -Destination (Invoke-Swift build @options --show-bin-path | Select-Object -Last 1)
    Invoke-Swift test --skip-build @options
}
