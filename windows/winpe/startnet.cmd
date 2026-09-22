@echo off
rem Runs instead of Windows Setup when the build boots WinPE.
rem
rem Two jobs, both done with Microsoft's own tools rather than reimplemented on
rem Linux:
rem
rem   bcdboot  the image has an empty ESP, and Windows will not boot natively
rem            without a BCD in it
rem   dism     install.wim ships no driver for any real machine's GPU, so any
rem            INF packages the build handed us go into the image's driver
rem            store now, offline, before it ever boots
rem
rem The log is copied to the ESP on the way out, where the build can read it
rem back with mtools without mounting anything.

set LOG=X:\winpe.log
echo === win11-ventoy-setup winpe phase === > %LOG%

wpeinit >> %LOG% 2>&1

rem Find the Windows volume first, and reach the ESP through it. Selecting a
rem volume in diskpart also selects the disk that holds it, so partition 1 is
rem then that disk's ESP - no assumption about which disk number the image
rem being built happens to get, which matters because WinPE boots from a disk
rem of its own here.
set W=
for %%d in (C D E F G H) do if exist %%d:\Windows\System32\winload.efi set W=%%d
if "%W%"=="" (
  echo ERROR: no volume with \Windows\System32\winload.efi >> %LOG%
  goto :save
)
echo windows volume: %W%: >> %LOG%

echo select volume %W% > X:\dp.txt
echo select partition 1 >> X:\dp.txt
echo assign letter=S >> X:\dp.txt
diskpart /s X:\dp.txt >> %LOG% 2>&1

bcdboot %W%:\Windows /s S: /f UEFI >> %LOG% 2>&1
echo bcdboot exit code: %errorlevel% >> %LOG%
dir S:\EFI\Microsoft\Boot >> %LOG% 2>&1

rem The driver payload is its own disk with a basic-data partition, which is
rem the one thing WinPE is certain to give a drive letter: it does not letter
rem EFI System Partitions, which is why the ESP above needs diskpart.
set D=
for %%d in (C D E F G H) do if exist %%d:\drivers\payload.tag set D=%%d
if "%D%"=="" (
  echo no driver payload attached - skipping dism >> %LOG%
  goto :save
)
echo driver payload: %D%:\drivers >> %LOG%

rem WinPE's scratch space is a 32 MB RAM disk and a graphics package is an
rem order of magnitude larger than that, so DISM gets a scratch directory on
rem the target volume instead.
mkdir %W%:\bm-scratch 2>nul
dism /image:%W%:\ /add-driver /driver:%D%:\drivers /recurse /scratchdir:%W%:\bm-scratch >> %LOG% 2>&1
echo dism exit code: %errorlevel% >> %LOG%
rd /s /q %W%:\bm-scratch 2>nul

:save
copy %LOG% S:\winpe.log >nul 2>&1
copy X:\Windows\Logs\DISM\dism.log S:\dism.log >nul 2>&1
wpeutil shutdown
