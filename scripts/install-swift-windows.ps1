# Installs the swift.org toolchain for this machine's processor, checked against its pinned checksum. The
# installer puts Swift on this user's PATH for new terminals; in a GitHub Actions job it also goes on the PATH
# of the job's later steps. Visual Studio provides the Windows SDK.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/windows-common.ps1"
# Swift 6.4, the same as the Linux builds.
$version = '6.4.1'
$installer = @{
    arm64 = @{ Suffix = '-arm64'; Sha256 = 'FAFF6A12CDAE099D76372CA971B0C83B13280AD704E1022FAA599DBE0B146E64' }
    x86_64 = @{ Suffix = ''; Sha256 = '9382E14919EEAE5E7B5DBFE0575452FE2154178E089A595C8B44D03960D91D59' }
}[(Get-MachineArchitecture)]
$suffix = $installer.Suffix
$work = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) "swift-$([guid]::NewGuid())")
try {
    $file = Join-Path $work "swift-$version$suffix.exe"
    Invoke-WebRequest "https://download.swift.org/swift-$version-release/windows10$suffix/swift-$version-RELEASE/swift-$version-RELEASE-windows10$suffix.exe" -OutFile $file
    if ((Get-FileHash -Algorithm SHA256 $file).Hash -ne $installer.Sha256) { throw 'Swift installer checksum mismatch.' }
    Start-Process -Wait -FilePath $file -ArgumentList '/quiet', '/norestart'
} finally {
    Remove-Item -Recurse -Force $work
}

if (-not $env:GITHUB_ACTIONS) {
    Write-Output "Installed Swift $version. Open a new terminal to use it."
    return
}
$swift = Join-Path $env:LOCALAPPDATA 'Programs/Swift'
Add-Content $env:GITHUB_PATH (Join-Path $swift "Toolchains/$version+Asserts/usr/bin")
Add-Content $env:GITHUB_PATH (Join-Path $swift "Runtimes/$version/usr/bin")
Add-Content $env:GITHUB_ENV "SDKROOT=$(Join-Path $swift "Platforms/$version/Windows.platform/Developer/SDKs/Windows.sdk")"
