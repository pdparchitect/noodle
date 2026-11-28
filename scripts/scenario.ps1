[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name,
    [switch]$List,
    [switch]$Parity,
    [switch]$All,
    [switch]$Shots,
    [switch]$Replay,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scenarios = Join-Path $root Scenarios
$windows = Join-Path $root Windows
$fixtures = @(Get-ChildItem -LiteralPath $scenarios -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName scenario.json) -PathType Leaf } |
    Sort-Object Name)

if ($List) {
    $fixtures.Name
    return
}
if ([bool]$All -eq [bool]$Name -and !($Parity -and !$Name -and !$All)) { throw 'Specify a scenario name or -All. Use -List to see available scenarios.' }
if ($Replay -and ($All -or $Shots -or $Parity)) { throw 'Use -Replay when opening a single fixture.' }
if ($Name) {
    $fixtures = @($fixtures | Where-Object Name -CEQ $Name)
    if ($fixtures.Count -eq 0) { throw "Unknown scenario '$Name'." }
}

if ($Parity) {
    # Inventory fixture requirements that the Windows launcher does not yet exercise.
    foreach ($fixture in $fixtures) {
        $definition = Get-Content -LiteralPath (Join-Path $fixture.FullName scenario.json) -Raw | ConvertFrom-Json
        $gaps = @(
            foreach ($key in @('appearance', 'settings', 'film')) {
                if ($null -ne $definition.$key) { $key }
            }
            foreach ($property in $definition.present.PSObject.Properties) {
                if ($property.Name -notin @('select', 'draft') -and $null -ne $property.Value) {
                    "present.$($property.Name)"
                }
            }
            foreach ($agent in $definition.agents) {
                if ($agent.avatar) { 'agent.avatar' }
                if ($agent.status) { 'agent.status' }
                if ($agent.tasks) { 'agent.tasks' }
                if ($agent.autoReplies) { 'agent.autoReplies' }
            }
            foreach ($conversation in $definition.conversations) {
                if ($conversation.background) { 'conversation.background' }
                foreach ($message in $conversation.messages) {
                    if ($message.attachments) { 'message.attachments' }
                    if ($message.reactions) { 'message.reactions' }
                }
            }
            foreach ($step in $definition.timeline) {
                foreach ($property in $step.PSObject.Properties) {
                    if ($property.Name -notin @('agent', 'in', 'wait', 'reply', 'say', 'type', 'present') -and
                        $null -ne $property.Value) {
                        "timeline.$($property.Name)"
                    }
                }
                foreach ($property in $step.present.PSObject.Properties) {
                    if ($property.Name -notin @('select', 'draft') -and $null -ne $property.Value) {
                        "timeline.present.$($property.Name)"
                    }
                }
            }
        )
        [pscustomobject]@{ Scenario = $fixture.Name; Pending = ($gaps | Sort-Object -Unique) -join ', ' }
    }
    return
}

if (!$NoBuild) {
    & swift build --package-path $windows
    if ($LASTEXITCODE -ne 0) { throw "Windows build failed with exit code $LASTEXITCODE." }
}
$bin = & swift build --package-path $windows --show-bin-path
if ($LASTEXITCODE -ne 0) { throw 'Swift could not resolve the Windows products directory.' }
$exe = Join-Path ($bin | Select-Object -Last 1) NoodleWindows.exe
if (!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Build NoodleWindows first. Expected $exe." }

if ($Shots) {
    Add-Type -AssemblyName System.Drawing
    if (!('ScenarioCapture' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ScenarioCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
}
'@
    }
    [void][ScenarioCapture]::SetProcessDPIAware()
}

$results = foreach ($fixture in $fixtures) {
    $p = $null
    $ready = $false
    try {
        $arguments = @('--scenario', $fixture.Name)
        if ($Replay) { $arguments += '--replay' }
        $p = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $root -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 200
            $p.Refresh()
            if ($p.HasExited) { throw "App exited with code $($p.ExitCode) before opening a window." }
        } until ($p.MainWindowHandle -ne [IntPtr]::Zero -or [DateTime]::UtcNow -ge $deadline)
        if ($p.MainWindowHandle -eq [IntPtr]::Zero) { throw 'Timed out waiting for the app window.' }
        $ready = $true

        if ($Shots) {
            $handle = $p.MainWindowHandle
            [void][ScenarioCapture]::SetForegroundWindow($handle)
            Start-Sleep -Milliseconds 800
            $rect = New-Object ScenarioCapture+Rect
            if (![ScenarioCapture]::GetWindowRect($handle, [ref]$rect)) { throw 'Could not read the window bounds.' }
            $directory = New-Item -ItemType Directory -Force -Path (Join-Path $fixture.FullName shots-windows)
            $bitmap = [Drawing.Bitmap]::new(($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try { $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size) }
                finally { $graphics.Dispose() }
                $bitmap.Save((Join-Path $directory.FullName initial.png), [Drawing.Imaging.ImageFormat]::Png)
            } finally { $bitmap.Dispose() }
        }
        [pscustomobject]@{ Scenario = $fixture.Name; Result = 'Opened'; Detail = '' }
    } catch {
        [pscustomobject]@{ Scenario = $fixture.Name; Result = 'Failed'; Detail = $_.Exception.Message }
    } finally {
        if (($All -or !$ready) -and $p -and !$p.HasExited) {
            if (!$p.CloseMainWindow() -or !$p.WaitForExit(3000)) { $p.Kill(); $p.WaitForExit() }
        }
        if ($p) { $p.Dispose() }
    }
}

$results | Format-Table -AutoSize
if ($results.Result -contains 'Failed') { exit 1 }
