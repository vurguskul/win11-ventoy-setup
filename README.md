# boot-media

Builds bootable media for a Ventoy USB stick. Everything here is **additive**:
no script formats, repartitions, or reinstalls Ventoy, and none of them touch
files they did not create. The stick keeps its existing ISOs, persistence
files, and documents.

## Windows 11 on Ventoy

A natively-bootable Windows 11 VHDX, built from an ISO on Linux, with a local
account and no Microsoft account prompt. Windows Setup is finished *before* the
image reaches the stick, so it boots straight to the login screen.

```bash
cp windows/win11.conf.example windows/win11.conf   # edit ISO path, edition, size
make list-editions                                 # see what your ISO contains
make windows                                       # build + copy to the stick
```

The build runs in a container, so the host needs only **docker** and
**`/dev/kvm`** — no wimlib, no ntfs-3g, no qemu, and no root. It prompts once
for the local account password and is otherwise unattended. Budget 30–60
minutes and ~60 GB free in `out/`: most of it is applying the WIM and running
Windows Setup once inside QEMU.

### How it boots

Ventoy's grub does this (see `grub/grub.cfg` on the stick's VTOYEFI partition,
`vhdboot_common_func`):

```
vt_load_vhdboot  ventoy/ventoy_vhdboot.img   load a boot image into RAM
vt_patch_vhdboot "<your.vhdx>"               patch its BCD to point at the VHDX
chainloader ... memdisk:<patched image>      boot it
```

**bootmgr and the BCD come from Ventoy, not from inside the VHDX.** That single
fact is what makes this buildable on Linux at all:

- the VHDX needs no `bcdboot` for Ventoy's sake, and nothing inside it is used
  to boot
- no Windows machine, and no `BCD-SYS`-style BCD authoring, is involved

The image does still get a GPT **ESP + MSR + Windows** layout, and its ESP does
get a real BCD — not for Ventoy, which ignores both, but so that Setup can be
finished at build time. The next two sections are about why.

`ventoy_vhdboot.img` ships separately from Ventoy itself, at
[github.com/ventoy/vhdiso](https://github.com/ventoy/vhdiso/releases).
`make vhdboot` fetches it and installs it at `/ventoy/ventoy_vhdboot.img`.
Without it the Ventoy menu prints *"Please put the right ventoy_vhdboot.img
file to the 1st partition"* and stops.

### Why the WIM is applied directly instead of installing in a VM

The common way to make a Windows VHD is to install it inside VirtualBox or
QEMU and move the disk out. For Windows 11 that is exactly the recipe that
fails on Ventoy — Setup binds the install to the VM's virtual TPM, and the
result dies at boot on real hardware. The usual workaround is a pile of
`LabConfig` registry bypasses.

Applying `install.wim` with `wimapply` never runs Windows Setup's *install*
phase, so there is no hardware check to bypass and no TPM binding to inherit.
No `LabConfig` keys are needed, and no TPM is attached to the build VM either.

Setup's **out-of-box** phase still runs, though, and that is the part that
takes work.

### The system partition Ventoy cannot provide

Applying the WIM leaves `HKLM\SYSTEM\Setup\CmdLine` set, so the first boot runs
`setup.exe -newsetup` — Setup's out-of-box phase, which performs the
`specialize` and `oobeSystem` passes and processes `unattend.xml`. That phase
wants a **system partition**, and under Ventoy there is never one.

Setup logs the reason itself:

```
LogBootDeviceInfo: The firmware boot device ARC path is [multi(0)disk(0)cdrom(0)]
                   and NT path is [].
LogBootDeviceInfo: The system boot device ARC path is
                   [multi(0)disk(0)vdisk(0)partition(3)]
                   and NT path is [\Device\Harddisk1\Partition3].
```

The OS half resolves to the VHDX's Windows volume, which is why the install
runs at all. The firmware half is Ventoy's memdisk and has **no NT path**.

Two separate components then fail on it, both with the same status:

```
SYSPRP BCD: Failed to get system partition. Status: c0000452      <- Sysprep-SpBcd
IBSLIB BFSVC: Failed to get partition name. Status = 0xc0000452   <- MungeBootEntries
```

`0xc0000452` is `STATUS_SYSTEM_DEVICE_NOT_FOUND`, and the emphasis belongs on
*system device*: Windows resolves the system partition from the device the
**firmware** booted from, not by scanning the OS disk for a partition carrying
the ESP type GUID. Three things follow, each of which was tried:

- **Giving the image an ESP does not help.** The failing image's ESP came back
  empty, still carrying an untouched `mkfs.fat` signature.
- **Deleting `Microsoft-Windows-Sysprep-SpBcd` from `Specialize.xml` only moves
  the failure.** `specialize` then completes, and Setup dies one stage later in
  `CallBack_MungeBootEntries` with *"Windows could not update the computer's
  boot configuration. Installation cannot proceed."*
- **`HKLM\SYSTEM\Setup\SystemPartition` is a dead end.** It exists in the
  applied image, holding a stale `\Device\HarddiskVolume1`, and
  `\Device\HarddiskVolumeN` numbering is assigned at boot from the volumes the
  host machine has — unfixable for a stick that moves between machines.

So the out-of-box phase cannot be made to work on the stick. It runs during the
build instead.

### Where Setup runs instead

Two QEMU boots at build time, off the image's *own* ESP, where the boot chain
is ordinary:

1. **`winpe`** — the image's ESP is empty and `bcdboot` does not exist on
   Linux. Rather than author a BCD by hand with hivex, the build boots the
   ISO's own WinPE and lets Microsoft's tool write it, from a FAT32 disk with
   a real ESP — OVMF reads UDF and FAT but has no ISO9660 driver, and this
   xorriso cannot write UDF, so an ISO of our own gives the firmware nothing
   to mount. `boot.wim` holds two images, and the build retargets its boot
   index to **image 1, plain WinPE**: image 2 is Windows Setup, whose registry
   carries `HKLM\SYSTEM\Setup\CmdLine=setup.exe`, so winlogon launches Setup
   and [`startnet.cmd`](windows/winpe/startnet.cmd) never runs. That script
   finds the Windows volume by looking for `winload.efi`, then reaches the ESP
   with diskpart's `select volume` — which selects that volume's disk too, so
   nothing depends on which disk number the image happens to get.
2. **`deploy`** — the image now boots natively. `specialize` succeeds, BFSVC
   writes boot entries into a real ESP, OOBE processes `unattend.xml`, and the
   last first-logon command powers the machine off. The build treats that
   power-off as the success signal — it only runs if OOBE got that far — then
   carves the NTFS volume back out and checks that `C:\Users\<you>` exists and
   that `setupact.log` reached `IMAGE_STATE_COMPLETE`.

Screenshots of both guests land in `out/` every minute, which is the only way
to see what a `-display none` VM is stuck on.

By the time the VHDX reaches the stick, `HKLM\SYSTEM\Setup\CmdLine` is clear
and Setup never runs again — so what Ventoy's memdisk does or does not provide
stops mattering. Ventoy still supplies the bootmgr and BCD that actually boot
it; the image's own ESP goes unused at runtime.

### The container, and why nothing needs root

The previous build worked through kernel block devices: `qemu-nbd` to attach
the image, `mount` to write into it, `sudo` for both, and a retry loop around
the nbd module's startup races. None of that survives. Every filesystem is
created and populated as a plain file, which is what makes the container
unprivileged — it runs as your own uid.

| Step | How |
| --- | --- |
| read the ISO | `7z` — install.wim is 7.6 GB so it lives only in the ISO's UDF filesystem, past ISO9660's 4 GB limit; libarchive sees two entries, and a loop mount would need privileges |
| partition | `sgdisk` writes the GPT into the disk file |
| format | `mkfs.vfat`; `mkntfs --partition-start` on the NTFS file — a file answers no geometry ioctls, so the start LBA is passed explicitly, and `hidden_sectors` must equal it or Windows cannot locate the volume within the disk |
| apply the WIM | `wimapply` to the NTFS **file**: libntfs-3g takes a regular file, and its backend is what preserves security descriptors, hard links, short names and reparse points |
| `unattend.xml` | injected into the WIM with `wimupdate`, since `ntfscp` cannot create `\Windows\Panther` |
| assemble | `dd` each partition into the disk image at its own offset |
| inspect the ESP | `mtools` with an `offset=` drive definition, reading straight out of the assembled disk |
| convert | `qemu-img convert -O vhdx` |

`make shell` opens a shell in the same image with `out/` mounted at `/work`.
`windows/build-vhdx.sh --stop-after <stage>` stops after `extract`, `volumes`,
`apply`, `assemble`, `winpe`, `deploy` or `verify`, and `--reuse-disk` keeps an
existing `out/disk.raw` and starts at the `winpe` phase — a failed boot phase
should not cost another eight-minute WIM apply. The ISO extraction in
`out/iso/` is cached across runs the same way.

### The local account

`windows/unattend/unattend.xml.tmpl` is rendered into
`C:\Windows\Panther\unattend.xml` and processed during the `deploy` boot.
`<HideOnlineAccountScreens>` is the element that matters — without it Windows 11
parks on "Sign in with Microsoft" with no way past.

The password is never written to the repo. `windows/build.sh` prompts for it on
the host, encodes it the way unattend expects (base64 of UTF-16LE of password +
element name) and passes it to the container on **stdin** — never as an
argument or an environment variable, both of which `docker inspect` and the
process list would show.

The template also sets a **one-time auto-logon** (`LogonCount` 1). OOBE ends at
the lock screen, and `FirstLogonCommands` only run when someone signs in — so
without it the build's own shutdown never fires and the deploy phase waits
until it times out. It is spent during the build; the machine you boot from the
stick comes up at the login screen like any other.

Five first-logon commands run, once, during the build:

| Command | Why |
| --- | --- |
| `diskpart` SAN policy `OfflineAll` | stops Windows mounting and writing to the internal disks of whatever host it is booted on |
| `PreventDeviceEncryption=1` | device encryption would bind the install to one machine's TPM and make it unbootable on the next |
| `powercfg /h off`, `HiberbootEnabled=0` | fast startup makes a "shut down" a kernel hibernate, and resuming that on a different machine bugchecks or corrupts the volume; see [Moving the stick between machines](#moving-the-stick-between-machines) |
| clear `AutoAdminLogon` / `DefaultPassword` | Windows is meant to drop these once `LogonCount` runs out; doing it explicitly means the shipped image cannot be carrying a plaintext password even if it does not |
| `shutdown /s /t 0` | OOBE runs inside QEMU, so the image puts itself away when it is done; the build waits for that power-off |

### Drivers, and why the list is all network adapters

`install.wim`'s only display driver is `basicdisplay.inf`. On real hardware
that is the **Microsoft Basic Display Adapter** — a framebuffer sitting at
whatever mode the firmware's GOP left behind, with no way to drive the
machine's other display pipes. It looks like an odd resolution on the laptop
panel and an external monitor that never lights up. There is no inbox driver
for any modern GPU — not Intel, not AMD, not NVIDIA.

Windows Update fixes that on first boot, for free, with the right driver for
whatever GPU it finds. What it cannot do is bootstrap itself: a laptop whose
Wi-Fi card has no inbox driver has no network, so it never reaches Windows
Update, so it never gets the GPU driver either. **Networking is the only thing
that has to be in the image.** Everything else follows from it — and a
graphics package is 500–900 MB for one machine's GPU, against ~190 MB for
network drivers covering most machines you will meet.

So `windows/drivers.txt` lists network adapters, by hardware ID:

```
intel-wifi          PCI\VEN_8086&DEV_51F0
mediatek-wifi-7921  PCI\VEN_14C3&DEV_7961
realtek-lan         PCI\VEN_10EC&DEV_8168
...
```

`make drivers` — which `make windows` runs for you — looks each one up in the
**Microsoft Update Catalog** and fetches it. That is where Windows Update
itself gets drivers, so the answer to a hardware-ID query is the driver
Windows would have installed anyway, delivered as a plain `.cab` of INF files
with no installer wrapper to defeat. `lspci -nn` gives you the IDs on the
Linux side: `8086:9a78` is spelled `PCI\VEN_8086&DEV_9A78` here. A direct URL
works as an entry too, and anything dropped into `windows/drivers/` by hand is
injected just the same — `windows/drivers/README.md` covers that.

The shipped list is 11 packages, ~60 MB downloaded, ~190 MB in the driver
store, carrying ~128 device IDs: Intel AX201–AX411 and BE200, MediaTek
MT7921/7922/7925, Qualcomm WCN685x, Realtek RTL8852AE/BE, Realtek and Intel
Ethernet, and an RTL8153 USB dongle as a last resort. What each package
actually covers was read back out of its INFs rather than taken from the
vendor's description — the MT7922 package does not cover MT7921, and the
RTL8852BE one does not cover RTL8852AE. What is already inbox was checked
against this ISO and left out: Intel AX200/AX210, Realtek RTL8821CE/8822CE,
Qualcomm QCA6174, Intel I219/I225, ASIX USB Ethernet, and RNDIS — so a phone
on a USB cable is the escape hatch when nothing else matches.

Each package is fetched once into `windows/drivers/<name>/` and then left
alone, so the drivers an image was built with do not change underneath you
between builds; delete the directory to take a newer one.

**How they get in.** DISM, in the WinPE phase that runs anyway for `bcdboot`,
so it costs no extra boot. The packages are carried in on a disk of their own
with a *basic data* partition rather than on the WinPE disk: WinPE does not
assign drive letters to EFI System Partitions, which is also why the target
ESP needs `diskpart` before `bcdboot` can write to it. The build prints every
INF it found and fails if DISM does not report success.

### Moving the stick between machines

Injected drivers cost nothing until the hardware they match turns up — PnP
binds by hardware ID and ignores the rest — and the driver store *accumulates*
rather than replaces. Get the Intel laptop online and Windows Update gives it
an Intel GPU driver; boot the AMD box and Windows Update adds a Radeon one
next to it. Both machines stay correct, and each keeps its own binding. The
only price is driver-store space, which never shrinks: `pnputil /enum-drivers`
shows what has piled up, and Disk Cleanup's "Device driver packages" prunes
superseded versions.

Stick to what Windows Update delivers. Vendor installer `.exe`s (Intel
Graphics Software, AMD Adrenalin) additionally install services and tray apps
that assume their GPU is present, and on a roaming image you end up carrying
two vendors' broken background services.

Nothing else about the image is machine-specific. Setup finished at build time
and never runs again, the boot path comes from Ventoy, device encryption is
off so nothing is bound to a TPM, and the controllers needed to boot are all
inbox — `mshdc.inf` for AHCI, `stornvme.inf` for NVMe, `usbxhci.inf` and
`uaspstor.inf` for the stick itself. **An AMD machine boots this image as
happily as an Intel one.** Its chipset is better covered than Intel's:
`amdgpio2.inf` and `amdi2c.inf` are inbox, so I²C touchpads work without help.
Each new machine costs one "Setting up devices" pass on first boot there.

The one thing that matters more than drivers here is that **hibernation is
off**. Fast startup makes a "shut down" a kernel hibernate, and resuming that
on the next machine brings back a kernel that believes it still has the
previous machine's GPU, chipset and storage stack — a bugcheck at best, a
corrupted volume at worst. `powercfg /h off` runs as a first-logon command
during the build, which takes fast startup with it; `HiberbootEnabled=0` is
set as well, so anything that later re-enables hibernation cannot bring fast
startup back with it. Windows To Go disabled both for the same reason.

### Verifying

The `deploy` phase *is* the test: an image that does not finish Setup never
powers off, and the build fails with the guest's last screenshot and the
`setupact.log` / `setuperr.log` it carved back out of the volume.

`make test-boot` additionally boots the **physical stick** in QEMU under OVMF,
which exercises Ventoy's grub, the BCD patching and winload together. It runs
QEMU with `-snapshot`, so every write lands in a throwaway overlay and the
stick is never modified, and it unmounts the exFAT partition on the host first
so the guest does not read a half-written filesystem. Booting the VHDX on its
own would fail by design — it has no bootmgr that Ventoy has not supplied.

### Space

`out/` holds the ISO extraction (~8 GB, kept so a re-run skips it), the raw
disk under construction (~15 GB), and the finished VHDX (~17 GB); peak is
around 55–60 GB. `make clean` removes all of it.

A dynamic VHDX only consumes what Windows has actually used, but Windows
believes it has the full virtual size. **If the stick fills up before the VHDX
reaches that size, the filesystem inside it corrupts.**
`windows/copy-to-stick.sh` warns when the virtual size exceeds free space on
the stick.

### Requirements

**docker**, and **`/dev/kvm`** readable by you. Without KVM the build still
works but Setup's out-of-box phase runs under emulation, which takes hours
rather than minutes. No Windows machine is involved at any point.

`make test-boot` is the one exception: it boots the physical stick, so it needs
`qemu-system-x86_64`, `edk2-ovmf` and `sudo` on the host. It shows the VM over
**VNC** and needs no QEMU UI package — Arch ships those separately
(`qemu-ui-gtk` and friends) and VNC is built into the qemu-system binary. It is
also the only thing that works unattended there, because that VM runs under
`sudo` and sudo strips `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`, leaving a GTK
window nothing to attach to on a Wayland session. Set `DISPLAY_MODE=gtk` to
override once `qemu-ui-gtk` is installed and you are on X11.

## Layout

```
docker/Dockerfile              the build environment; nothing else is installed
lib/common.sh                  shared helpers
ventoy/fetch-vhdboot.sh        install ventoy_vhdboot.img on the stick
windows/build.sh               host side: inputs, password, docker run
windows/build-vhdx.sh          the pipeline, inside the container
windows/drivers.txt            driver packages to fetch, by hardware ID
windows/fetch-drivers.sh       host side of the fetch: docker run
windows/fetch-drivers.py       the fetch, inside the container
windows/winpe/startnet.cmd     what WinPE runs instead of Setup: bcdboot, dism
windows/drivers/               vendor INF packages to inject (gitignored)
windows/copy-to-stick.sh       host side: copy the finished VHDX to the stick
windows/test-boot.sh           boot the stick in QEMU, read-only
windows/unattend/              unattend.xml template
windows/win11.conf.example     copy to win11.conf and edit
out/                           build output and logs (gitignored)
```
