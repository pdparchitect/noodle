# Replaces the Noodle agent with C:\noodle\NoodleAgent.cs, which Noodle Computer has just sent, and starts it
# again. Run detached by the agent it replaces; a source that does not compile leaves the old agent in place.
$ErrorActionPreference = 'Continue'
$n = 'C:\noodle'
Start-Transcript -Path "$n\update.log" -Append
Start-Sleep -Seconds 1
$csc = "$env:WINDIR\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
Remove-Item -Force "$n\NoodleAgent.new.exe" -ErrorAction SilentlyContinue
& $csc /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$n\NoodleAgent.new.exe" "$n\NoodleAgent.cs"
if ($LASTEXITCODE -eq 0 -and (Test-Path "$n\NoodleAgent.new.exe")) {
    Stop-ScheduledTask -TaskName NoodleAgent
    Get-Process NoodleAgent -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Move-Item -Force "$n\NoodleAgent.new.exe" "$n\NoodleAgent.exe"
}
Start-ScheduledTask -TaskName NoodleAgent
Stop-Transcript
