@echo off
rem Runs instead of Windows Setup when the repair boots WinRE against an image
rem that will no longer start.
rem
rem What it is for: Windows Update offers HP (and Dell, and Lenovo) BIOS
rem updates as a driver in the "Firmware" device class. Installing one stages a
rem UEFI capsule on the system partition and asks the firmware to flash it on
rem the next boot. This image has no system partition of its own - Ventoy boots
rem it from a BCD in a memdisk - so the update cannot complete, and Windows
rem retries it on every boot: "Undoing changes made to your computer", reboot,
rem again, forever.
rem
rem Four jobs, all of them offline, on a volume nothing is running from:
rem
rem   revertpendingactions   backs the half-installed servicing operation out,
rem                          which is what breaks the reboot loop
rem   remove-driver          takes the firmware driver package out of the
rem                          image's driver store, so nothing re-stages it
rem   reg add                writes the device-installation policy that stops
rem                          Windows installing a firmware update again
rem   del                    drops the downloaded payload and any staged
rem                          capsule, so Windows Update starts from a clean
rem                          slate rather than replaying the same failure
rem
rem The log goes to the payload disk, which is a plain FAT32 file on the host:
rem that is how the repair reports what it did without mounting anything.

set LOG=X:\repair.log
echo === win11-ventoy-setup repair phase === > %LOG%

wpeinit >> %LOG% 2>&1

rem The image being repaired is the volume with a Windows on it. WinPE's own
rem X: is a RAM disk and is never a candidate.
set W=
for %%d in (C D E F G H) do if exist %%d:\Windows\System32\winload.efi set W=%%d
if "%W%"=="" (
  echo ERROR: no volume with \Windows\System32\winload.efi >> %LOG%
  goto :save
)
echo windows volume: %W%: >> %LOG%

rem The results disk: a basic-data FAT32 volume, which WinPE letters
rem automatically, recognised by content because its drive letter is not
rem knowable on the host side.
set R=
for %%d in (C D E F G H) do if exist %%d:\repair\payload.tag set R=%%d
if "%R%"=="" echo WARNING: no results disk attached - the log cannot be saved >> %LOG%

rem Selecting a volume in diskpart also selects the disk that holds it, so
rem partition 1 is then that disk's ESP - no assumption about which disk number
rem the image happens to get.
echo select volume %W% > X:\dp.txt
echo select partition 1 >> X:\dp.txt
echo assign letter=S >> X:\dp.txt
diskpart /s X:\dp.txt >> %LOG% 2>&1

rem WinPE's scratch space is a 32 MB RAM disk, and servicing an image needs
rem more than that, so DISM gets a scratch directory on the target volume.
mkdir %W%:\bm-scratch 2>nul
set DISM=dism /image:%W%:\ /scratchdir:%W%:\bm-scratch

echo. >> %LOG%
echo --- pending servicing operations --- >> %LOG%
if exist %W%:\Windows\WinSxS\pending.xml echo pending.xml is present >> %LOG%
%DISM% /cleanup-image /revertpendingactions >> %LOG% 2>&1
echo revertpendingactions exit code: %errorlevel% >> %LOG%
rem 0x800f082f is "there was nothing pending", which is a success for us: it is
rem what a healthy image says, and what this one should say on a second run.
if exist %W%:\Windows\WinSxS\pending.xml echo WARNING: pending.xml is still there >> %LOG%

echo. >> %LOG%
echo --- third-party drivers in the image --- >> %LOG%
%DISM% /get-drivers /format:table >> %LOG% 2>&1
rem Published name is the first column; the class name is the fourth. Anything
rem in the Firmware class is a BIOS update waiting to happen, so it goes.
for /f "tokens=1 delims=|" %%a in ('%DISM% /get-drivers /format:table ^| findstr /i "firmware"') do call :rmdrv %%a

echo. >> %LOG%
echo --- blocking firmware device installs --- >> %LOG%
rem The policy that stops this happening again. DenyDeviceClasses with the
rem Firmware setup class {f2e7dd72-6468-4e36-b6f1-6488f42c1b52} refuses the
rem install of any firmware update device; Retroactive applies it to one that
rem is already there. Ordinary drivers - the GPU, wifi - are untouched, which
rem is the point of blocking by class rather than turning driver updates off.
rem Written into the offline SOFTWARE hive, so it is in force on the very first
rem boot after this repair.
set RK=HKLM\BM_SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
reg load HKLM\BM_SOFTWARE %W%:\Windows\System32\config\SOFTWARE >> %LOG% 2>&1
reg add "%RK%" /v DenyDeviceClasses /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%RK%" /v DenyDeviceClassesRetroactive /t REG_DWORD /d 1 /f >> %LOG% 2>&1
reg add "%RK%\DenyDeviceClasses" /v 1 /t REG_SZ /d "{f2e7dd72-6468-4e36-b6f1-6488f42c1b52}" /f >> %LOG% 2>&1
reg query "%RK%" /s >> %LOG% 2>&1
rem The hive must be unloaded or its changes stay in the log file next to it,
rem and the image boots as if nothing was written.
reg unload HKLM\BM_SOFTWARE >> %LOG% 2>&1
echo reg unload exit code: %errorlevel% >> %LOG%

echo. >> %LOG%
echo --- clearing the update queue --- >> %LOG%
rem The downloaded payload is what Windows Update would replay on the next
rem boot. Deleting it costs nothing - it is a cache, and a re-scan refills it
rem with whatever is still applicable, which the policy above no longer is.
if exist %W%:\Windows\SoftwareDistribution\Download (
  rd /s /q %W%:\Windows\SoftwareDistribution\Download
  echo removed SoftwareDistribution\Download >> %LOG%
)
rem A capsule staged on the image's own ESP would be handed to the firmware by
rem the next boot loader that looks at it.
if exist S:\EFI\UpdateCapsule (
  rd /s /q S:\EFI\UpdateCapsule
  echo removed \EFI\UpdateCapsule from the ESP >> %LOG%
)

rd /s /q %W%:\bm-scratch 2>nul
echo. >> %LOG%
echo === repair finished === >> %LOG%

:save
if not "%R%"=="" copy %LOG% %R%:\repair\repair.log >nul 2>&1
if not "%R%"=="" copy X:\Windows\Logs\DISM\dism.log %R%:\repair\dism.log >nul 2>&1
wpeutil shutdown
goto :eof

rem Called once per line of dism /get-drivers that mentions firmware. %1 is the
rem published name, oemNN.inf; cmd trims the column padding on the way in.
:rmdrv
if /i not "%~x1"==".inf" goto :eof
echo removing driver package %1 >> %LOG%
%DISM% /remove-driver /driver:%1 >> %LOG% 2>&1
echo remove-driver %1 exit code: %errorlevel% >> %LOG%
goto :eof
