# Generates the Swift projections of WinUI 3, the Windows App SDK and the Windows SDK that the app uses, into
# Bindings\ (ignored by git: the C headers alone are some 50 MB). Run it once before `swift build`, and again
# after changing $Include or a version below.
#
#   .\generate-bindings.ps1                        # swiftwinrt.exe from nuget.org
#   .\generate-bindings.ps1 -SwiftWinRT <path>     # a newer swiftwinrt.exe, such as one built from swift-winrt's main
param([string]$SwiftWinRT = "")
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Bindings = Join-Path $PSScriptRoot "Bindings"
$Packages = Join-Path $Bindings "Packages"
# The parts of Windows App SDK 1.8.260921001 that hold WinUI's metadata, and the Bootstrap DLL.
$Nuget = [ordered]@{
    "TheBrowserCompany.SwiftWinRT" = "0.6.0"
    "Microsoft.WindowsAppSDK.Foundation" = "1.8.260803002"
    "Microsoft.WindowsAppSDK.InteractiveExperiences" = "1.8.260708001"
    "Microsoft.WindowsAppSDK.WinUI" = "1.8.260803003"
    "Microsoft.Web.WebView2" = "1.0.3179.45"
}
$WindowsSDK = "10.0.26100.0"
# The types the app uses; swiftwinrt adds what they need.
$Include = @(
    "Microsoft.UI.Xaml.Application"
    "Microsoft.UI.Xaml.Hosting.WindowsXamlManager"
    "Microsoft.UI.Dispatching.DispatcherQueueController"
    "Microsoft.UI.Xaml.Window"
    "Microsoft.UI.Xaml.Controls.XamlControlsResources"
    "Microsoft.UI.Xaml.XamlTypeInfo.XamlControlsXamlMetaDataProvider"
    "Microsoft.UI.Xaml.Controls.NavigationView"
    "Microsoft.UI.Xaml.Controls.NavigationViewItem"
    "Microsoft.UI.Xaml.Controls.NavigationViewItemHeader"
    "Microsoft.UI.Xaml.Controls.InfoBadge"
    "Microsoft.UI.Xaml.Controls.Grid"
    "Microsoft.UI.Xaml.Controls.StackPanel"
    "Microsoft.UI.Xaml.Controls.TextBlock"
    "Microsoft.UI.Xaml.Controls.TextBox"
    "Microsoft.UI.Xaml.Controls.Button"
    "Microsoft.UI.Xaml.Controls.ListView"
    "Microsoft.UI.Xaml.Controls.FontIcon"
    "Microsoft.UI.Xaml.Controls.PersonPicture"
    "Microsoft.UI.Xaml.Controls.TitleBar"
    "Microsoft.UI.Xaml.Controls.ToolTipService"
    "Microsoft.UI.Xaml.Automation.AutomationProperties"
    "Microsoft.UI.Xaml.Media.MicaBackdrop"
    "Microsoft.UI.Xaml.Markup.XamlReader"
)

New-Item -ItemType Directory -Force $Packages | Out-Null
foreach ($id in $Nuget.Keys) {
    $folder = Join-Path $Packages "$id.$($Nuget[$id])"
    if (Test-Path $folder) { continue }
    $name = $id.ToLower(); $version = $Nuget[$id]
    Invoke-WebRequest -UseBasicParsing "https://api.nuget.org/v3-flatcontainer/$name/$version/$name.$version.nupkg" -OutFile "$folder.zip"
    Expand-Archive "$folder.zip" $folder
    Remove-Item "$folder.zip"
}
if (-not $SwiftWinRT) { $SwiftWinRT = Join-Path $Packages "TheBrowserCompany.SwiftWinRT.$($Nuget['TheBrowserCompany.SwiftWinRT'])\bin\swiftwinrt.exe" }

$Output = Join-Path $Bindings "Generated"
if (Test-Path $Output) { Remove-Item -Recurse -Force $Output }
$Arguments = @("-output $Output", "-input $WindowsSDK")
foreach ($id in $Nuget.Keys) {
    Get-ChildItem (Join-Path $Packages "$id.$($Nuget[$id])") -Filter *.winmd -Recurse | ForEach-Object { $Arguments += "-input $($_.FullName)" }
}
$Arguments += $Include | ForEach-Object { "-include $_" }
$Response = Join-Path $Bindings "swiftwinrt.rsp"
$Arguments | Out-File $Response -Encoding ascii
& $SwiftWinRT "@$Response"
if ($LASTEXITCODE -ne 0) { throw "swiftwinrt failed with $LASTEXITCODE" }
Move-Item (Join-Path $Output "Sources\*") $Output
Remove-Item (Join-Path $Output "Sources")

# An unpackaged app finds the Windows App Runtime through this DLL; the app loads it from beside itself or from here.
$Architecture = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
Copy-Item (Join-Path $Packages "Microsoft.WindowsAppSDK.Foundation.$($Nuget['Microsoft.WindowsAppSDK.Foundation'])\runtimes\win-$Architecture\native\Microsoft.WindowsAppRuntime.Bootstrap.dll") $Bindings
"Bindings generated in $Output"
