# Copies Microsoft's msquic.dll for this machine's processor into a folder, from its NuGet package pinned by
# checksum: the OpenSSL build, which reads the PEM certificates the Hub link pins, as Schannel's cannot.
param([Parameter(Mandatory)] [string] $Destination)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$version = '2.6.4'
$sha256 = '370BAF73845AC516A7ACB53394EBF889CA947F7826A0E74F8F8C332B3627ADB5'
$arch = @{ ARM64 = 'arm64'; AMD64 = 'x64' }[$env:PROCESSOR_ARCHITECTURE]
if (-not $arch) { throw 'msquic is fetched for arm64 and x86_64 only.' }
$package = Join-Path ([IO.Path]::GetTempPath()) "msquic-openssl-$version.zip"
Invoke-WebRequest "https://www.nuget.org/api/v2/package/Microsoft.Native.Quic.MsQuic.OpenSSL/$version" -OutFile $package
if ((Get-FileHash -Algorithm SHA256 $package).Hash -ne $sha256) { throw 'msquic package checksum mismatch.' }
$unpacked = Join-Path ([IO.Path]::GetTempPath()) "msquic-openssl-$version"
Remove-Item -Recurse -Force $unpacked -ErrorAction SilentlyContinue
Expand-Archive $package $unpacked
New-Item -ItemType Directory -Force $Destination | Out-Null
Copy-Item (Join-Path $unpacked "build/native/bin/$arch/msquic.dll") $Destination
