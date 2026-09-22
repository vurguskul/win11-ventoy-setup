# win11-ventoy-setup

This project builds a Windows 11 disk image on Linux. The image is a VHDX file,
which is a virtual disk that Windows can start from directly. You copy the file
to a USB stick that runs Ventoy, and the machine then starts Windows from the
stick.

Windows Setup finishes during the build, before the file reaches the stick. The
image therefore starts at the login screen of a local account. Windows does not
ask for a Microsoft account.

Every step adds files. No step formats the stick, changes its partitions, or
installs Ventoy again. No script deletes a file that it did not write. The stick
keeps its ISO files, its persistence files, and its documents.

```bash
cp windows/win11.conf.example windows/win11.conf   # edit ISO path, edition, size
make list-editions                                 # see what your ISO contains
make windows                                       # build the VHDX into out/
make install                                       # copy it onto the stick
```

The build asks for the name and the password of the local account. It asks
nothing else. The build takes 30 to 60 minutes.

## Prerequisites

The build runs in a Docker container under your own user ID. The host needs
Docker. The host does not need wimlib, ntfs-3g, qemu, root permission, or a
Windows machine.

| Requirement | Notes |
| --- | --- |
| docker | The only program that the host must have. `make windows` builds the container on the first run. |
| `/dev/kvm`, with read and write permission for your user | KVM is the hardware acceleration that Linux gives to virtual machines. Without it, qemu emulates the processor, and the two virtual machines in the build take hours instead of minutes. On Arch Linux, add your user to the `kvm` group. |
| A Windows 11 ISO file that contains `sources/install.wim` | Windows can start from a VHDX file only in the Pro, Enterprise, and Education editions. The Home edition has no license for it. |
| About 60 GB of free space in `out/` | The files from the ISO, the disk under construction, and the finished VHDX exist at the same time. See [Space](#space). |
| A Ventoy stick, already installed and mounted | Only the targets that write to the stick need it. The scripts find the stick by the partition label `Ventoy`. |
| `pv`, `qemu-system-x86_64`, `edk2-ovmf`, `sudo` | Optional. `pv` draws a progress bar for the copy to the stick. The other three programs run `make test-boot`. |

The configuration is the file `windows/win11.conf`. Copy
`windows/win11.conf.example` to that name and edit it. You can also give each
value to `windows/build.sh` on the command line, where it replaces the value
from the file: `--iso`, `--edition`, `--size`, `--block-size`, `--drivers`,
`--user`, `--computer`, `--locale`, `--input-locale`, `--timezone`.

## Make targets

| Target | What it does |
| --- | --- |
| `make list-editions` | Print the editions in the configured ISO, with the name to put in `EDITION`. |
| `make vhdboot` | Install `ventoy_vhdboot.img` on the stick. It does nothing when the file is already there. |
| `make drivers` | Download the driver packages in `windows/drivers.txt`. It leaves the packages that are already there. |
| `make windows` | Build the VHDX into `out/win11.vhdx`. It runs `drivers` first. It does not write to the stick. |
| `make install` | Copy `out/win11.vhdx` to the stick. It runs `vhdboot` first. |
| `make repair` | Repair the image on the stick after a failed update. See [BIOS updates and the boot loop](#bios-updates-and-the-boot-loop). |
| `make test-boot` | Start the physical stick in QEMU with OVMF firmware, with no write to the stick. |
| `make screenshot` | Write the screen of a running `make test-boot` to `/tmp/win11-ventoy-screen.png`. |
| `make image` | Build the container again, after a change to `docker/Dockerfile`. |
| `make shell` | Open a shell in the container, with `out/` at `/work` and the repository at `/repo`. |
| `make clean` | Delete the contents of `out/`. |

The build and the copy to the stick are two separate targets. `make windows`
writes only to `out/`. The stick does not have to be in the machine during a
build of one hour. A build that fails cannot have written to it. To put the
image on a second stick, you copy a file. You do not build again.

## The boot sequence

The grub boot loader of Ventoy reads the file `ventoy/ventoy_vhdboot.img` into
memory. It changes the BCD in that file to point to your VHDX, and then starts
it. The BCD is the Boot Configuration Data store, which is the list of boot
entries that Windows reads at the start.

Ventoy supplies bootmgr and the BCD. The VHDX does not contain them. This is the
reason that you can build the image on Linux. No part of the image needs
`bcdboot`, which runs only on Windows.

`ventoy_vhdboot.img` is a separate download from Ventoy itself. It is at
[github.com/ventoy/vhdiso](https://github.com/ventoy/vhdiso/releases). `make
vhdboot` installs it, and `make install` installs it before it copies an image.
Without the file, the Ventoy menu prints "Please put the right
ventoy_vhdboot.img file to the 1st partition" and stops.

The image still gets a GPT partition table with an ESP, an MSR, and a Windows
partition, and a real BCD on the ESP. The ESP is the EFI System Partition, the
small FAT partition that the firmware starts from. Ventoy uses neither the ESP
nor the BCD in the image. They exist so that Setup can finish during the build.

## Why Setup runs during the build

The build applies `install.wim` with `wimapply`. `install.wim` is the archive in
the ISO that holds the Windows files. The build does not install Windows in a
virtual machine.

An installation in a virtual machine connects Windows 11 to the virtual TPM of
that machine. The TPM is the security chip that Windows 11 requires. The result
then fails to start on real hardware. The usual `LabConfig` registry changes
exist for that problem. `wimapply` copies files. It does not run the install
phase of Setup, so there is no hardware test to avoid and no TPM to inherit.

The out-of-box phase of Setup must still run one time. This phase, which Windows
calls OOBE, creates the first user account. It cannot run on the stick. It needs
a system partition, and under Ventoy the firmware starts from a disk in memory,
which has no NT device path. Windows reads the system partition from the device
that the firmware started from. Windows never searches the disk for it. An ESP
in the image therefore does not help.

The build runs that phase in two QEMU virtual machines that start from the ESP
of the image. There the boot sequence is normal.

The first virtual machine runs WinPE, which is a small Windows that runs from
memory. It writes the BCD of the image with `bcdboot` and adds the drivers with
DISM. This WinPE comes from `Winre.wim` in the image under construction, not
from `boot.wim` in the ISO. In the WinPE of `boot.wim`, DISM services no offline
image.

The second virtual machine starts Windows from that BCD. OOBE reads
`unattend.xml`, and the last first logon command turns the machine off. The
build treats that power off as the success signal. The build then makes sure
that `C:\Users\<name>` exists and that `setupact.log` reached
`IMAGE_STATE_COMPLETE`.

When the VHDX reaches the stick, Setup does not run again. What the disk in
memory of Ventoy does not supply is then no longer important.

The build writes a screenshot of each virtual machine to `out/` every minute.
The virtual machines run with `-display none`, so the screenshots are the only
way to see where a machine stopped.

`windows/build-vhdx.sh --stop-after <stage>` stops the build after one stage:
`extract`, `volumes`, `apply`, `assemble`, `winpe`, `deploy`, or `verify`.
`--reuse-disk` keeps the file `out/disk.raw` from the last run and starts at the
`winpe` stage. A virtual machine that fails then does not cost another WIM
apply.

No step writes to a kernel block device. `sgdisk`, `mkntfs
--partition-start`, `wimapply` through libntfs-3g, `mtools` with an `offset=`
drive definition, and `dd` all work on plain files. The container therefore
needs no `mount`, no `qemu-nbd`, and no `sudo`.

## The local account

The build writes `windows/unattend/unattend.xml.tmpl` to
`C:\Windows\Panther\unattend.xml`, with your values in it. Windows reads that
file in the second virtual machine. The important element is
`<HideOnlineAccountScreens>`. Without it, Windows 11 stops at the screen "Sign
in with Microsoft", and there is no way past that screen.

The build asks for the account name at the start. There is no default value, so
no name from the build host goes into the image. The build tests the name
against the Windows rules for a local account name before it starts the work.
Windows creates the account late in the second virtual machine. A name that
Windows rejects gives you a finished image that you cannot log in to. To skip
the question, set `USERNAME` in `windows/win11.conf`, or pass `--user`.

The password never goes into the repository. `windows/build.sh` asks for it on
the host and gives it to the container on standard input. The password is never
a command line argument and never an environment variable, because `docker
inspect` and the process list show both.

The template also sets an automatic logon for one logon (`LogonCount` 1). The
commands under `FirstLogonCommands` run only when a user logs in, and OOBE
otherwise stops at the lock screen. The build uses that one logon. The machine
that you start from the stick shows the login screen like any other machine.

These commands run one time, during the build:

| Command | Why |
| --- | --- |
| `diskpart` SAN policy `OfflineAll` | Windows then does not mount and does not write to the internal disks of the host machine. |
| `PreventDeviceEncryption=1` | Device encryption connects the installation to the TPM of one machine. |
| `powercfg /h off`, `HiberbootEnabled=0` | Fast startup turns a shutdown into a hibernation of the kernel. See [Use on more than one machine](#use-on-more-than-one-machine). |
| `DenyDeviceClasses` for the Firmware class | See [BIOS updates and the boot loop](#bios-updates-and-the-boot-loop). |
| Delete `AutoAdminLogon` and `DefaultPassword` | The image must not carry a readable password. |
| `shutdown /s /t 0` | The machine turns itself off when OOBE ends, and the build waits for that power off. |

## Drivers

The only display driver in `install.wim` is `basicdisplay.inf`. Windows has no
built-in driver for a modern GPU. Windows Update installs one at the first
start, at no cost. But Windows Update cannot start itself. A laptop with a Wi-Fi
card that has no built-in driver never reaches Windows Update. Network drivers
are therefore the only drivers that the image must contain. A graphics package
is 500 to 900 MB for the GPU of one machine. The network drivers are about 190
MB in total, and they cover most machines.

`windows/drivers.txt` lists network adapters by hardware ID. A hardware ID is
the identifier that Windows uses to select a driver for a device.

```
intel-wifi          PCI\VEN_8086&DEV_51F0
mediatek-wifi-7921  PCI\VEN_14C3&DEV_7961
realtek-lan         PCI\VEN_10EC&DEV_8168
```

`make drivers` searches each ID in the Microsoft Update Catalog. Windows Update
takes its drivers from the same catalog, so the answer to a hardware ID query is
the driver that Windows installs by itself. The driver arrives as a plain `.cab`
file, with no installer program around it. `lspci -nn` prints the IDs of your
machine. The ID `8086:9a78` is written `PCI\VEN_8086&DEV_9A78`. A direct URL is
also a valid entry, and the build adds any package that you put into
`windows/drivers/` by hand. See
[`windows/drivers/README.md`](windows/drivers/README.md).

The list has 11 packages, about 60 MB, and it covers about 128 device IDs. The
packages are Wi-Fi and Ethernet drivers from Intel, MediaTek, Qualcomm, and
Realtek, and one driver for an RTL8153 USB adapter as a last resort. The
coverage comes from the INF files in each package, not from the text of the
vendor. For example, the package for the MT7922 does not cover the MT7921.
Drivers that the ISO already has stay out of the list. RNDIS is one of them, so
a telephone on a USB cable is the last way to get a network.

The build downloads each package one time into `windows/drivers/<name>/` and
then leaves it alone. The drivers in an image therefore do not change without
your action. To take a newer package, delete the directory.

## Use on more than one machine

An extra driver costs nothing until its hardware appears. The driver store adds
drivers. It does not replace them. Connect the Intel laptop to a network, and
Windows Update adds an Intel GPU driver. Start the AMD machine, and Windows
Update adds a Radeon driver beside it. Both machines then work. The only cost is
space in the driver store, which never becomes smaller. The option "Device
driver packages" in Disk Cleanup deletes the old versions.

Use only the drivers that Windows Update supplies. The installer programs of the
vendors (Intel Graphics Software, AMD Adrenalin) also install services and tray
programs. Those programs expect their own GPU in the machine.

Nothing else in the image belongs to one machine. Setup does not run again, and
Ventoy supplies the boot path. Device encryption is off, and Windows has
built-in drivers for all the controllers that it needs to start. Each new
machine costs one "Setting up devices" pass at the first start there.

Hibernation is more important than the drivers, and it must stay off. Fast
startup turns a shutdown into a hibernation of the kernel. If that machine
resumes on the next machine, the kernel expects the GPU, the chipset, and the
storage of the machine before. The best result is a bug check. The worst result
is a damaged volume. The build runs `powercfg /h off` and also sets
`HiberbootEnabled=0`. A later change that turns hibernation on again therefore
cannot bring fast startup back with it.

## BIOS updates and the boot loop

Windows Update offers the BIOS updates of a vendor as a driver in the Firmware
device class. The installation writes a UEFI capsule to the system partition. A
UEFI capsule is the file that the firmware reads at the next start to write the
new BIOS. This image has no system partition, so the write to the BIOS can never
happen. Windows does not stop. It tries again at every start: "Working on
updates", "Undoing changes made to your computer", restart, and again. You
cannot log in.

The build blocks that one device class. It adds the GUID of the Firmware setup
class to `DenyDeviceClasses` under
`HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions`. This
restriction is narrower than `ExcludeWUDriversInQualityUpdate`, which stops all
driver updates. The GPU and Wi-Fi drivers that Windows Update finds on each new
machine are the reason that this image works on more than one machine. Windows
refuses firmware only, and it refuses it before it writes anything.

Do not update the BIOS from this image. Use the boot media of the vendor, or the
Windows installation on the internal disk of the machine.

To repair an image that is already in the loop, run one of these commands:

```bash
make repair                                  # the stick's /ventoy/win11.vhdx
windows/repair.sh --vhdx out/win11.vhdx      # some other image, in place
```

The repair starts the WinRE of the image against the image in QEMU. WinRE is the
recovery version of Windows in the image. It runs four operations on the image
while Windows in it is off:

1. `dism /cleanup-image /revertpendingactions` removes the operation that
   Windows started and did not finish.
2. `dism /remove-driver` deletes the Firmware class package from the driver
   store.
3. A registry write puts the policy above into the offline `SOFTWARE` hive.
4. The repair deletes `SoftwareDistribution\Download` and any UEFI capsule under
   `\EFI\UpdateCapsule` on the ESP.

DISM performs the revert at the next start of the image. Expect one more
"Undoing changes" pass on the machine. That pass completes, because the driver
package is gone and the policy keeps it out.

The repair copies the image from the stick to `out/rescue/` and repairs the
copy. It then asks you before it copies the repaired image back. An image that
already fails is not an image to write to without a way back. Until you answer
that question, the stick holds the file that it held before. `--yes` skips the
question. `--refresh` takes a new copy over a copy that is already in
`out/rescue/`. `--in-place` repairs the file on the stick directly. A copy back
needs space for two images at the same time. A stick that holds a VHDX that has
grown rarely has that space. For that reason, `copy-to-stick.sh --replace`
deletes the image on the stick first. It deletes no file that it did not write.

## Tests

The second virtual machine of the build is the test. An image that does not
finish Setup never turns off. The build then fails and gives you the last
screenshot of the virtual machine and the files `setupact.log` and
`setuperr.log` from the image.

`make test-boot` starts the physical stick in QEMU with OVMF firmware. It tests
the grub of Ventoy, the change to the BCD, and winload together. It runs with
`-snapshot`, so every write goes to a temporary file. It also unmounts the exFAT
partition on the host first, so that the virtual machine does not read a
half-written file system. The VHDX alone cannot start, by design. It has no
bootmgr, because Ventoy supplies it.

This is the only target that needs programs on the host:
`qemu-system-x86_64`, `edk2-ovmf`, and `sudo`. It shows the virtual machine over
VNC. The virtual machine runs under `sudo`, and `sudo` deletes
`WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` from the environment. A GTK window then
has no display to attach to. If you installed `qemu-ui-gtk` and you use X11, set
`DISPLAY_MODE=gtk`.

## Space

`out/` holds the files from the ISO (about 8 GB, kept so that the next run can
skip the extraction), the disk under construction (about 15 GB), and the
finished VHDX (about 17 GB). The maximum is 55 to 60 GB. `make clean` deletes
all of it. `make repair` needs space for one more copy of the image from the
stick. That copy is larger than the image that the build made, because a dynamic
VHDX grows when Windows writes to it.

A dynamic VHDX uses only the space that Windows has written, but Windows
believes that it has the full virtual size. If the stick becomes full before the
VHDX reaches that size, the file system in the image is damaged. Do not set the
virtual size above the free space on the stick. `windows/copy-to-stick.sh` gives
a warning when the virtual size is larger than the free space on the stick.

## Layout

```
docker/Dockerfile              the build environment, and nothing else
lib/                           shared helpers, and the WinPE disk builder
ventoy/fetch-vhdboot.sh        install ventoy_vhdboot.img on the stick
windows/build.sh               host side of the build: inputs, account, password
windows/build-vhdx.sh          the build pipeline, inside the container
windows/repair.sh              host side of the repair: copy off the stick
windows/repair-vhdx.sh         the repair, inside the container
windows/winpe/                 what WinPE runs during a build and a repair
windows/drivers.txt            driver packages to fetch, by hardware ID
windows/fetch-drivers.sh       host side of the fetch, done by fetch-drivers.py
windows/drivers/               vendor INF packages to inject (gitignored)
windows/copy-to-stick.sh       host side: copy a VHDX to the stick
windows/test-boot.sh           boot the stick in QEMU, read-only
windows/screenshot.sh          grab the screen of a running test-boot over QMP
windows/unattend/              unattend.xml template
windows/win11.conf.example     copy to win11.conf and edit
out/                           build output, logs, rescue copies (gitignored)
```
