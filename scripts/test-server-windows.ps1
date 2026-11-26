# Tests Noodle Server on Windows and what it builds on there: the live views' wire, and the Hub link over
# msquic, whose tests load msquic.dll from beside their runner as noodled.exe will from beside itself.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/windows-common.ps1"
$root = Split-Path -Parent $PSScriptRoot

foreach ($package in @(@{ Path = 'Shared/Surface'; Scratch = 'windows-surface' }, @{ Path = 'Shared/HubLink'; Scratch = 'windows-hub-link' })) {
    $options = @('--package-path', "$root/$($package.Path)", '--scratch-path', "$root/.build/$($package.Scratch)") + $SwiftWindowsFlags
    Invoke-Swift build --build-tests @options
    & "$PSScriptRoot/fetch-msquic-windows.ps1" -Destination (Invoke-Swift build @options --show-bin-path | Select-Object -Last 1)
    Invoke-Swift test --skip-build @options
}
