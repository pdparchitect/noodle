# Copies Microsoft's msquic.dll for a processor (this machine's unless given) into a folder, from its NuGet
# package pinned by checksum: the OpenSSL build, which reads the PEM certificates the Hub link pins, as
# Schannel's cannot. It carries its own OpenSSL, so bump the version here when OpenSSL security fixes land.
param([Parameter(Mandatory)] [string] $Destination, [string] $Architecture)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/windows-common.ps1"
$version = '2.6.4'
$sha256 = '370BAF73845AC516A7ACB53394EBF889CA947F7826A0E74F8F8C332B3627ADB5'
if (-not $Architecture) { $Architecture = Get-MachineArchitecture }
$folder = @{ arm64 = 'arm64'; x86_64 = 'x64' }[$Architecture]
if (-not $folder) { throw "msquic is fetched for arm64 and x86_64 only, not $Architecture." }
$work = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) "msquic-$([guid]::NewGuid())")
try {
    $package = Join-Path $work "msquic-openssl-$version.zip"
    Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Native.Quic.MsQuic.OpenSSL/$version" -OutFile $package
    if ((Get-FileHash -Algorithm SHA256 $package).Hash -ne $sha256) { throw 'msquic package checksum mismatch.' }
    Expand-Archive $package (Join-Path $work 'package')
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Copy-Item (Join-Path $work "package/build/native/bin/$folder/msquic.dll") $Destination
} finally {
    Remove-Item -Recurse -Force $work
}
