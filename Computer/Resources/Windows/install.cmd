@echo off
rem Installs Windows from WinPE in place of Windows Setup, which fails on this hardware, then shuts down.
rem %1 is the install media's drive letter. Noodle Computer follows over the virtio-serial port
rem org.noodle.progress: "step: ..." lines and DISM's own progress. "step: done" means installed.
set M=%1
set LOG=X:\noodle-install.log
set PORT=\\.\Global\org.noodle.progress
echo %DATE% %TIME% install start > %LOG%
drvload %M%:\noodle\drivers\vioserial\vioser.inf >> %LOG% 2>&1
set OUT=%LOG%
for /l %%i in (1,1,15) do (
    (echo step: Preparing the disk) > %PORT% 2>nul && (set OUT=%PORT%& goto ported)
    ping -n 2 127.0.0.1 >nul
)
:ported
(
echo select disk 0
echo clean
echo convert gpt
echo create partition efi size=300
echo format quick fs=fat32 label=System
echo assign letter=S
echo create partition msr size=16
echo create partition primary
echo format quick fs=ntfs label=Windows
echo assign letter=W
) > X:\dp.txt
diskpart /s X:\dp.txt >> %LOG% 2>&1 || (set FAILED=preparing the disk& goto fail)
call :step "Copying Windows"
dism /Apply-Image /ImageFile:%M%:\sources\install.swm /SWMFile:%M%:\sources\install*.swm /Index:1 /ApplyDir:W:\ > %OUT% 2>&1 || (set FAILED=copying Windows& goto fail)
call :step "Adding drivers"
dism /Image:W:\ /Add-Driver /Driver:%M%:\noodle\drivers /Recurse >> %LOG% 2>&1 || (set FAILED=adding drivers& goto fail)
call :step "Finishing"
xcopy /e /i /y %M%:\noodle\guest W:\noodle >> %LOG% 2>&1 || (set FAILED=copying the Noodle agent& goto fail)
mkdir W:\Windows\Panther 2>nul
copy /y %M%:\noodle\unattend.xml W:\Windows\Panther\unattend.xml >> %LOG% 2>&1 || (set FAILED=copying the answer file& goto fail)
bcdboot W:\Windows /s S: /f UEFI >> %LOG% 2>&1 || (set FAILED=making the disk bootable& goto fail)
call :step "done"
wpeutil shutdown
exit /b 0
:fail
call :step "failed: %FAILED%"
if not "%OUT%"=="%LOG%" type %LOG% > %PORT% 2>nul
wpeutil shutdown
exit /b 1

:step
echo %DATE% %TIME% %~1 >> %LOG%
if not "%OUT%"=="%LOG%" (echo step: %~1) > %PORT% 2>nul
exit /b 0
