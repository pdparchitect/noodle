# Runs once, at the first sign-in: builds the Noodle agent with the .NET Framework's compiler and
# starts it at every sign-in; keeps the computer awake and without a lock screen; turns hibernation off.
$ErrorActionPreference = 'Continue'
$n = 'C:\noodle'
Start-Transcript -Path "$n\setup.log" -Append
$csc = "$env:WINDIR\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" }
& $csc /nologo /target:winexe /optimize+ /r:System.Web.Extensions.dll "/out:$n\NoodleAgent.exe" "$n\NoodleAgent.cs"

powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /h off
# After an unclean stop Windows would wait at Automatic Repair, on a screen the computer cannot show; it boots instead.
bcdedit /set '{default}' recoveryenabled No
bcdedit /set '{default}' bootstatuspolicy IgnoreAllFailures
New-Item -Force 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name NoLockScreen -Value 1 -Type DWord

$action = New-ScheduledTaskAction -Execute "$n\NoodleAgent.exe" -WorkingDirectory $n
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName NoodleAgent -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
Start-ScheduledTask -TaskName NoodleAgent
Stop-Transcript
