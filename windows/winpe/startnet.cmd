@echo off
rem Runs instead of Windows Setup when the build boots WinPE.
rem
rem Its whole job is bcdboot: the image has an empty ESP, and Windows will not
rem boot natively without a BCD in it. bcdboot is the tool that knows what a
rem correct BCD looks like, so the build borrows it from Microsoft rather than
rem authoring the store by hand.
rem
rem The log is copied to the ESP on the way out, where the build can read it
rem back with mtools without mounting anything.

set LOG=X:\bcdboot.log
echo === boot-media bcdboot phase === > %LOG%

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

:save
copy %LOG% S:\bcdboot.log >nul 2>&1
wpeutil shutdown
