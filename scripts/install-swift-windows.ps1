# Installs the swift.org toolchain for this machine's processor, checked against its pinned checksum, and
# puts it on the PATH of a GitHub Actions job's later steps. The image's Visual Studio provides the Windows SDK.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The Swift 6.4 SwiftTUI needs.
$version = '6.4.1'
$installers = @{
    ARM64 = @{ Suffix = '-arm64'; Sha256 = 'FAFF6A12CDAE099D76372CA971B0C83B13280AD704E1022FAA599DBE0B146E64' }
    AMD64 = @{ Suffix = ''; Sha256 = '9382E14919EEAE5E7B5DBFE0575452FE2154178E089A595C8B44D03960D91D59' }
}
$installer = $installers[$env:PROCESSOR_ARCHITECTURE]
if (-not $installer) { throw 'Noodle Terminal is built for arm64 and x86_64 only.' }
$suffix = $installer.Suffix
$file = Join-Path ([IO.Path]::GetTempPath()) "swift-$version$suffix.exe"
Invoke-WebRequest "https://download.swift.org/swift-$version-release/windows10$suffix/swift-$version-RELEASE/swift-$version-RELEASE-windows10$suffix.exe" -OutFile $file
if ((Get-FileHash -Algorithm SHA256 $file).Hash -ne $installer.Sha256) { throw 'Swift installer checksum mismatch.' }
Start-Process -Wait -FilePath $file -ArgumentList '/quiet', '/norestart'

$swift = Join-Path $env:LOCALAPPDATA 'Programs/Swift'
Add-Content $env:GITHUB_PATH (Join-Path $swift "Toolchains/$version+Asserts/usr/bin")
Add-Content $env:GITHUB_PATH (Join-Path $swift "Runtimes/$version/usr/bin")
Add-Content $env:GITHUB_ENV "SDKROOT=$(Join-Path $swift "Platforms/$version/Windows.platform/Developer/SDKs/Windows.sdk")"
