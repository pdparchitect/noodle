@echo off
rem WinPE's shell on Noodle's install media, in place of Windows Setup: finds the install disk and runs
rem noodle\install.cmd from it, which installs Windows and shuts down. The serial driver comes with WinPE,
rem so Noodle Computer hears about it even when no install disk turns up.
wpeinit
drvload X:\noodle\vioserial\vioser.inf >nul 2>&1
set PORT=\\.\Global\org.noodle.progress
for /l %%i in (1,1,15) do (
    (echo step: Starting the installer) > %PORT% 2>nul && goto ported
    ping -n 2 127.0.0.1 >nul
)
:ported
for /l %%t in (1,1,10) do (
    for %%d in (C D E F G H I J K L M N O P) do if exist %%d:\noodle\install.cmd (
        call %%d:\noodle\install.cmd %%d
        exit /b 0
    )
    ping -n 3 127.0.0.1 >nul
)
(echo step: failed: no install disk was found) > %PORT% 2>nul
wmic logicaldisk get name,description,volumename > %PORT% 2>nul
wpeutil shutdown
