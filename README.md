# win11-ventoy-setup

Builds a natively-bootable Windows 11 VHDX for a Ventoy USB stick, from an ISO,
on Linux. Windows Setup is finished *before* the image reaches the stick, so it
boots straight to the login screen of a local account with no Microsoft account
prompt.

Everything here is **additive**: nothing formats, repartitions or reinstalls
Ventoy, and no script touches files it did not create. The stick keeps its
existing ISOs, persistence files and documents.

```bash
cp windows/win11.conf.example windows/win11.conf   # edit ISO path, edition, size
make list-editions                                 # see what your ISO contains
make windows                                       # build + copy to the stick
```

The build runs in a container, so the host needs only **docker** and
**`/dev/kvm`** — no wimlib, no ntfs-3g, no qemu, no root, and no Windows
machine. It prompts once for the local account password and is otherwise
unattended. Budget 30–60 minutes and ~60 GB free in `out/`.

`make help` lists the rest of the targets.

## How it boots

Ventoy's grub loads `ventoy/ventoy_vhdboot.img` into RAM, patches its BCD to
point at your VHDX, and chainloads it. **bootmgr and the BCD come from Ventoy,
not from inside the VHDX** — which is what makes the image buildable on Linux
at all: nothing inside it needs `bcdboot` for Ventoy's sake, and no
`BCD-SYS`-style BCD authoring is involved.

`ventoy_vhdboot.img` ships separately from Ventoy, at
[github.com/ventoy/vhdiso](https://github.com/ventoy/vhdiso/releases). `make
vhdboot` fetches it and installs it. Without it the Ventoy menu prints *"Please
put the right ventoy_vhdboot.img file to the 1st partition"* and stops.

The image still gets a GPT **ESP + MSR + Windows** layout with a real BCD on
its ESP. Ventoy ignores both; they exist so Setup can be finished at build
time.

## Why Setup runs at build time

`install.wim` is applied with `wimapply` rather than installed in a VM. A VM
install binds Windows 11 to the VM's virtual TPM and the result dies at boot on
real hardware, which is what the usual pile of `LabConfig` registry bypasses is
for. Applying the WIM never runs Setup's *install* phase, so there is no
hardware check to bypass and no TPM to inherit.

Setup's **out-of-box** phase still has to run once, and it cannot run on the
stick. It wants a system partition, and under Ventoy the firmware boot device
is a memdisk with no NT path, so both `Sysprep-SpBcd` and `MungeBootEntries`
fail with `0xc0000452`, `STATUS_SYSTEM_DEVICE_NOT_FOUND`. Windows resolves the
system partition from the device the *firmware* booted from, never by scanning
the OS disk — so giving the image an ESP does not help, dropping `SpBcd` from
`Specialize.xml` only moves the failure one stage later, and
`HKLM\SYSTEM\Setup\SystemPartition` is a dead end because
`\Device\HarddiskVolumeN` numbering is assigned at boot by the host machine.

So the out-of-box phase runs during the build instead, in two QEMU boots off
the image's *own* ESP, where the boot chain is ordinary:

1. **`winpe`** — writes the image's BCD with `bcdboot`, and injects drivers
   with DISM. The WinPE is **`Winre.wim` taken out of the image being built**,
   not the ISO's `boot.wim`: in boot.wim's WinPE, DISM cannot reach
   `dismhost.exe` over COM (`hr:0x80004002`) and services nothing offline, not
   even its own RAM disk. Deleting `winpeshl.ini` is what makes it run
   [`startnet.cmd`](windows/winpe/startnet.cmd) instead of the recovery shell.
   That script finds the Windows volume by looking for `winload.efi`, so
   nothing depends on which disk number the image gets.
2. **`deploy`** — the image boots natively from that BCD. `specialize`
   succeeds, BFSVC writes boot entries into a real ESP, OOBE processes
   `unattend.xml`, and the last first-logon command powers the machine off. The
   build treats that power-off as the success signal, then carves the NTFS
   volume back out and checks that `C:\Users\<you>` exists and `setupact.log`
   reached `IMAGE_STATE_COMPLETE`.

Screenshots of both guests land in `out/` every minute — the only way to see
what a `-display none` VM is stuck on.

By the time the VHDX reaches the stick, `HKLM\SYSTEM\Setup\CmdLine` is clear
and Setup never runs again, so what Ventoy's memdisk does not provide stops
mattering.

## Why nothing needs root

No step touches a kernel block device. Every filesystem is created and
populated as a plain file: `sgdisk` writes the GPT into the disk file, `mkntfs
--partition-start` formats the NTFS file (a file answers no geometry ioctls, so
the start LBA is passed explicitly, and `hidden_sectors` must match it or
Windows cannot find the volume), `wimapply` applies into that file through
libntfs-3g, `mtools` reads the ESP back out of the assembled disk with an
`offset=` drive definition, and `dd` puts the partitions together. The ISO is
read with `7z`, because `install.wim` is 7.6 GB and exists only in the UDF
filesystem, past ISO9660's 4 GB limit.

The container therefore runs as your own uid, with no `qemu-nbd`, no `mount`
and no `sudo`.

`make shell` opens a shell in the same image with `out/` mounted at `/work`.
`windows/build-vhdx.sh --stop-after <stage>` stops after `extract`, `volumes`,
`apply`, `assemble`, `winpe`, `deploy` or `verify`; `--reuse-disk` keeps an
existing `out/disk.raw` and starts at `winpe`, so a failed boot phase does not
cost another eight-minute WIM apply. The ISO extraction in `out/iso/` is cached
the same way.

## The local account

`windows/unattend/unattend.xml.tmpl` is rendered into
`C:\Windows\Panther\unattend.xml` and processed during the `deploy` boot.
`<HideOnlineAccountScreens>` is the element that matters — without it Windows 11
parks on "Sign in with Microsoft" with no way past.

The password never lands in the repo. `windows/build.sh` prompts for it on the
host, encodes it the way unattend expects, and passes it to the container on
**stdin** — never as an argument or an environment variable, both of which
`docker inspect` and the process list would show.

The template also sets a **one-time auto-logon** (`LogonCount` 1), because
`FirstLogonCommands` only run when someone signs in and OOBE otherwise ends at
the lock screen. It is spent during the build; the machine you boot from the
stick comes up at the login screen like any other.

Six first-logon commands run, once, during the build:

| Command | Why |
| --- | --- |
| `diskpart` SAN policy `OfflineAll` | stops Windows mounting and writing to the internal disks of whatever host it is booted on |
| `PreventDeviceEncryption=1` | device encryption would bind the install to one machine's TPM |
| `powercfg /h off`, `HiberbootEnabled=0` | fast startup makes a "shut down" a kernel hibernate; see [Moving between machines](#moving-between-machines) |
| `DenyDeviceClasses` for the Firmware class | see [BIOS updates](#bios-updates-and-the-boot-loop-they-cause) |
| clear `AutoAdminLogon` / `DefaultPassword` | the shipped image cannot be carrying a plaintext password even if Windows fails to drop these itself |
| `shutdown /s /t 0` | the image puts itself away when OOBE is done, and the build waits for that power-off |

## Drivers

`install.wim`'s only display driver is `basicdisplay.inf` — a framebuffer stuck
at whatever mode the firmware's GOP left behind, with no inbox driver for any
modern GPU. Windows Update fixes that on first boot, for free, but it cannot
bootstrap itself: a laptop whose Wi-Fi card has no inbox driver never reaches
Windows Update. **Networking is the only thing that has to be in the image.** A
graphics package is 500–900 MB for one machine's GPU, against ~190 MB of
network drivers covering most machines you will meet.

So `windows/drivers.txt` lists network adapters, by hardware ID:

```
intel-wifi          PCI\VEN_8086&DEV_51F0
mediatek-wifi-7921  PCI\VEN_14C3&DEV_7961
realtek-lan         PCI\VEN_10EC&DEV_8168
```

`make drivers` — which `make windows` runs for you — looks each one up in the
**Microsoft Update Catalog**, which is where Windows Update itself gets
drivers: the answer to a hardware-ID query is the driver Windows would have
installed anyway, as a plain `.cab` with no installer wrapper to defeat. `lspci
-nn` gives you the IDs (`8086:9a78` is spelled `PCI\VEN_8086&DEV_9A78`). A
direct URL works as an entry too, and anything dropped into `windows/drivers/`
by hand is injected just the same; see
[`windows/drivers/README.md`](windows/drivers/README.md).

The shipped list is 11 packages, ~60 MB downloaded, carrying ~128 device IDs:
Intel AX201–AX411 and BE200, MediaTek MT7921/7922/7925, Qualcomm WCN685x,
Realtek RTL8852AE/BE, Realtek and Intel Ethernet, and an RTL8153 USB dongle as
a last resort. Coverage comes from each package's INFs rather than the vendor's
description — the MT7922 package does not cover MT7921. What the ISO already
has inbox stays out: Intel AX200/AX210, Realtek RTL8821CE/8822CE, Qualcomm
QCA6174, Intel I219/I225, ASIX USB Ethernet, and RNDIS, so a phone on a USB
cable is the escape hatch when nothing else matches.

Each package is fetched once into `windows/drivers/<name>/` and then left
alone, so the drivers an image was built with do not change underneath you;
delete the directory to take a newer one. They are injected during the `winpe`
phase that runs anyway, so they cost no extra boot, and they ride in on a disk
of their own with a *basic data* partition because WinPE assigns no drive
letters to ESPs.

## Moving between machines

Injected drivers cost nothing until the hardware they match turns up, and the
driver store *accumulates* rather than replaces. Get the Intel laptop online
and Windows Update gives it an Intel GPU driver; boot the AMD box and Windows
Update adds a Radeon one next to it. Both machines stay correct. The only price
is driver-store space, which never shrinks — `pnputil /enum-drivers` shows what
has piled up, and Disk Cleanup's "Device driver packages" prunes superseded
versions.

Stick to what Windows Update delivers. Vendor installer `.exe`s (Intel Graphics
Software, AMD Adrenalin) also install services and tray apps that assume their
GPU is present, and on a roaming image you end up carrying two vendors' broken
background services.

Nothing else about the image is machine-specific: Setup never runs again, the
boot path comes from Ventoy, device encryption is off, and the controllers
needed to boot are all inbox (`mshdc.inf`, `stornvme.inf`, `usbxhci.inf`,
`uaspstor.inf`). An AMD machine boots this image as happily as an Intel one —
its chipset is better covered, since `amdgpio2.inf` and `amdi2c.inf` are inbox.
Each new machine costs one "Setting up devices" pass on first boot there.

What matters more than drivers is that **hibernation is off**. Fast startup
makes a "shut down" a kernel hibernate, and resuming that on the next machine
brings back a kernel that believes it still has the previous machine's GPU,
chipset and storage stack — a bugcheck at best, a corrupted volume at worst.
`HiberbootEnabled=0` is set alongside `powercfg /h off`, so anything that later
re-enables hibernation cannot bring fast startup back with it.

## BIOS updates, and the boot loop they cause

Windows Update offers vendor BIOS updates as a driver in the **Firmware**
device class. Installing one stages a UEFI capsule on the system partition,
which this image does not have — so the flash can never happen, and Windows
does not give up. It retries on every boot: *"Working on updates"*, *"Undoing
changes made to your computer"*, restart, repeat, with no way in.

The build blocks that one class, as a first-logon command:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions
    DenyDeviceClasses            = 1
    DenyDeviceClassesRetroactive = 1
    DenyDeviceClasses\1          = {f2e7dd72-6468-4e36-b6f1-6488f42c1b52}
```

That GUID is the Firmware setup class. The restriction is deliberately
narrower than `ExcludeWUDriversInQualityUpdate`, which turns off driver updates
altogether: the GPU and Wi-Fi drivers Windows Update finds on each new machine
are what make this image usable on more than one. Only firmware is refused, and
it is refused at installation, before anything is staged.

Flash the BIOS from the vendor's own boot media, or from the machine's own
installed Windows. Never from this one.

### Recovering an image caught in the loop

```bash
make repair                                  # the stick's /ventoy/win11.vhdx
windows/repair.sh --vhdx out/win11.vhdx      # some other image, in place
```

This boots the image's own WinRE against it in QEMU and runs four things
offline: `dism /cleanup-image /revertpendingactions` to back the half-installed
operation out, `dism /remove-driver` to take the Firmware-class package out of
the driver store, a `reg add` of the policy above into the offline `SOFTWARE`
hive, and an `rd /s /q` of `SoftwareDistribution\Download` and any
`\EFI\UpdateCapsule` staged on the ESP.

The stick's image is copied to `out/rescue/` and repaired there, then copied
back when you say so at the prompt — an image that is already failing is not
one to write to without a way back, and until that prompt is answered the stick
holds exactly what it held. `--yes` skips the prompt, `--refresh` takes a fresh
copy over one already in `out/rescue/`, and `--in-place` gives up the copy and
repairs the stick's file directly.

Putting one image back over another needs room for both at once, which a stick
holding a grown VHDX rarely has, so `copy-to-stick.sh --replace` deletes the
image already there first. It deletes nothing it did not write.

DISM reports *"Revert of pending actions will be attempted after the reboot"* —
the revert happens on the image's next boot, so expect one more "Undoing
changes" pass on the machine. That one completes: the driver package is gone,
and the policy will not let it come back.

## Verifying

The `deploy` phase *is* the test: an image that does not finish Setup never
powers off, and the build fails with the guest's last screenshot and the
`setupact.log` / `setuperr.log` it carved out of the volume.

`make test-boot` additionally boots the **physical stick** in QEMU under OVMF,
exercising Ventoy's grub, the BCD patching and winload together. It runs with
`-snapshot` so every write lands in a throwaway overlay, and unmounts the exFAT
partition on the host first so the guest does not read a half-written
filesystem. Booting the VHDX on its own would fail by design — it has no
bootmgr that Ventoy has not supplied.

This is the one thing that needs anything on the host: `qemu-system-x86_64`,
`edk2-ovmf` and `sudo`. It shows the VM over **VNC**, which is built into the
qemu-system binary, because that VM runs under `sudo` and sudo strips
`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`, leaving a GTK window nothing to attach to.
Set `DISPLAY_MODE=gtk` once `qemu-ui-gtk` is installed and you are on X11.

## Space

`out/` holds the ISO extraction (~8 GB, kept so a re-run skips it), the raw
disk under construction (~15 GB), and the finished VHDX (~17 GB); peak is
55–60 GB. `make clean` removes all of it. `make repair` wants room for one more
copy of the stick's image, which is larger than the built one because a dynamic
VHDX grows as Windows writes to it.

A dynamic VHDX only consumes what Windows has actually used, but Windows
believes it has the full virtual size. **If the stick fills up before the VHDX
reaches that size, the filesystem inside it corrupts.**
`windows/copy-to-stick.sh` warns when the virtual size exceeds free space on
the stick.

Without KVM the build still works, but Setup's out-of-box phase runs under
emulation and takes hours rather than minutes.

## Layout

```
docker/Dockerfile              the build environment; nothing else is installed
lib/common.sh                  shared helpers
lib/winpe.sh                   building and booting a WinPE disk; shared
ventoy/fetch-vhdboot.sh        install ventoy_vhdboot.img on the stick
windows/build.sh               host side of the build: inputs, password
windows/build-vhdx.sh          the build pipeline, inside the container
windows/repair.sh              host side of the repair: copy off the stick
windows/repair-vhdx.sh         the repair, inside the container
windows/winpe/startnet.cmd     what WinPE runs during the build: bcdboot, dism
windows/winpe/repair.cmd       what WinRE runs to back a failed update out
windows/drivers.txt            driver packages to fetch, by hardware ID
windows/fetch-drivers.sh       host side of the fetch: docker run
windows/fetch-drivers.py       the fetch, inside the container
windows/drivers/               vendor INF packages to inject (gitignored)
windows/copy-to-stick.sh       host side: copy a VHDX to the stick
windows/test-boot.sh           boot the stick in QEMU, read-only
windows/screenshot.sh          grab the screen of a running test-boot over QMP
windows/unattend/              unattend.xml template
windows/win11.conf.example     copy to win11.conf and edit
out/                           build output, logs, rescue copies (gitignored)
```
