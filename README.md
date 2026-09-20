# boot-media

Builds bootable media for a Ventoy USB stick. Everything here is **additive**:
no script formats, repartitions, or reinstalls Ventoy, and none of them touch
files they did not create. The stick keeps its existing ISOs, persistence
files, and documents.

## Windows 11 on Ventoy

A natively-bootable Windows 11 VHDX, built from an ISO on Linux, with a local
account and no Microsoft account prompt.

```bash
cp windows/win11.conf.example windows/win11.conf   # edit ISO path, edition, size
make list-editions                                 # see what your ISO contains
make windows                                       # build + copy to the stick
make test-boot                                     # verify in QEMU, stick untouched
```

`make windows` prompts once for the local account password and is otherwise
unattended. It takes roughly 10-15 minutes, almost all of it applying the WIM.

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

- the VHDX needs no EFI System Partition, no MSR, and no `bcdboot`
- it is a plain MBR disk with one active NTFS partition holding `\Windows`
- no Windows machine, and no `BCD-SYS`-style BCD authoring, is involved

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
phase, so there is no hardware check to bypass and no TPM binding to inherit. No
`LabConfig` keys are needed, and the build is minutes instead of an hour.

Setup's **out-of-box** phase still runs, though, and it is easy to forget that
it does. Applying the WIM leaves `HKLM\SYSTEM\Setup\CmdLine` set, so the first
boot runs `setup.exe -newsetup`, which performs the `specialize` and `oobeSystem`
passes. That is what processes `unattend.xml` — and what the next section is
about.

### The BCD sysprep module

Because Ventoy supplies bootmgr and the BCD, this VHDX has **no system
partition and no BCD store**. The specialize pass runs
`Microsoft-Windows-Sysprep-SpBcd`, whose job is to open the *system* BCD store
and write boot configuration into it. With no system partition it fails:

```
SYSPRP BCD: Failed to get system partition. Status: c0000452
SYSPRP Sysprep_Specialize_Bcd: There was an error opening the system store.
```

A single failed module aborts the whole pass, and Setup reports
**"Windows could not configure Windows to run on this computer's hardware"** —
a message that sounds like a hardware-compatibility rejection and is nothing of
the kind. Every other specialize module succeeds.

`build-vhdx.sh` removes both `Microsoft-Windows-Sysprep-SpBcd` blocks from
`C:\Windows\System32\Sysprep\ActionFiles\Specialize.xml` before first boot.
Nothing is lost: Ventoy re-patches the BCD it supplies on every boot, so
anything that module wrote would be discarded — and a BCD specialized for one
machine would be wrong on the next, which is the entire premise of a stick that
moves between machines.

`wimapply` writes to the **NTFS volume directly** (`/dev/nbd0p1`), not to a
mounted directory. Its ntfs-3g backend is what preserves security descriptors,
hard links, short names, and reparse points; applying into a mountpoint drops
all of that and produces an install that will not boot.

### The local account

`windows/unattend/unattend.xml.tmpl` is rendered into
`C:\Windows\Panther\unattend.xml` and runs on first boot.
`<HideOnlineAccountScreens>` is the element that matters — without it Windows 11
parks on "Sign in with Microsoft" with no way past.

The password is never written to the repo. `build-vhdx.sh` prompts for it and
encodes it the way unattend expects (base64 of UTF-16LE of password + element
name), so it is not stored in plaintext in the image either.

Two first-logon commands make the install portable, since it moves between
machines:

| Command | Why |
| --- | --- |
| `diskpart` SAN policy `OfflineAll` | stops Windows mounting and writing to the internal disks of whatever host it is booted on |
| `PreventDeviceEncryption=1` | device encryption would bind the install to one machine's TPM and make it unbootable on the next |

### Verifying without rebooting

`make test-boot` boots the **physical stick** in QEMU under OVMF. That is the
only meaningful test, because it exercises Ventoy's grub, the BCD patching, and
winload together. Booting the VHDX on its own would fail by design — it has no
bootmgr.

It runs QEMU with `-snapshot`, so every write lands in a throwaway overlay and
the stick is never modified. It unmounts the exFAT partition on the host first
so the guest does not read a half-written filesystem.

### Space

A dynamic VHDX only consumes what Windows has actually used, but Windows
believes it has the full virtual size. **If the stick fills up before the VHDX
reaches that size, the filesystem inside it corrupts.** `build-vhdx.sh` warns
when the virtual size exceeds free space on the stick. A Win11 install is
~25 GB applied.

### Requirements

```bash
sudo pacman -S --needed wimlib qemu-img qemu-base ntfs-3g parted edk2-ovmf
```

`make test-boot` shows the VM over **VNC** and needs no QEMU UI package: Arch
ships those separately (`qemu-ui-gtk` and friends) and `qemu-base` includes
none, so `-display gtk` fails with *"Display 'gtk' is not available"*. VNC is
built into the qemu-system binary. It is also the only thing that works
unattended here, because the VM runs under `sudo` and sudo strips
`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`, leaving a GTK window nothing to attach to
on a Wayland session. Set `DISPLAY_MODE=gtk` to override once `qemu-ui-gtk` is
installed and you are on X11.

`build-vhdx.sh` needs `sudo` for the loop mount, `qemu-nbd`, `mkntfs`, and
`wimapply`. It does not need a Windows machine at any point.

## Layout

```
lib/common.sh                  shared helpers
ventoy/fetch-vhdboot.sh        install ventoy_vhdboot.img on the stick
windows/build-vhdx.sh          the one command: ISO -> VHDX -> stick
windows/test-boot.sh           boot the stick in QEMU, read-only
windows/unattend/              unattend.xml template
windows/win11.conf.example     copy to win11.conf and edit
out/                           build output (gitignored)
```
