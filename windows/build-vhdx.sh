#!/usr/bin/env bash
#
# Build a natively-bootable Windows 11 VHDX from an ISO and drop it on an
# existing Ventoy stick, without touching anything else on the stick.
#
# How this boots, and why the VHDX looks so bare:
#
#   Ventoy's grub loads ventoy/ventoy_vhdboot.img into memory, patches the BCD
#   inside it to point at the VHDX you picked, and chainloads it. bootmgr and
#   the BCD therefore come from Ventoy, NOT from the image. That is why this
#   script builds an MBR disk with a single NTFS partition and no ESP, no MSR,
#   and no bcdboot - there is nothing for them to do.
#
# Why install.wim is applied directly instead of running Setup in a VM:
#
#   Windows 11 VHDs built by installing inside a VM are the ones that fail to
#   boot on Ventoy - Setup binds the install to the VM's virtual TPM. Applying
#   the WIM never runs Setup, so there is no hardware check and no TPM binding,
#   and none of the usual LabConfig bypass keys are needed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

# --- config -------------------------------------------------------------------

ISO=""; EDITION=""; SIZE="48G"; BLOCK_SIZE="1M"; USERNAME="egor"; COMPUTERNAME="WIN11-USB"
LOCALE="en-GB"; INPUTLOCALE="en-GB"; TIMEZONE="GMT Standard Time"
DEST_DIR="/ventoy"; OUT="$ROOT/out/win11.vhdx"
LIST_ONLY=0; NO_COPY=0; VENTOY=""

[[ -f $ROOT/windows/win11.conf ]] && source "$ROOT/windows/win11.conf"

usage() {
  cat <<'EOF'
usage: build-vhdx.sh [options]

  --iso PATH        Windows 11 ISO (default: from windows/win11.conf)
  --edition NAME    edition to apply, e.g. "Windows 11 Pro"
  --size SIZE       virtual size of the dynamic VHDX (default 48G)
  --block-size SIZE VHDX payload block size (default 1M, min 1M, max 256M)
  --dest DIR        directory on the Ventoy partition (default /ventoy)
  --out PATH        where to build before copying (default out/win11.vhdx)
  --ventoy MP       Ventoy mountpoint (default: autodetected by label)
  --list-editions   print the editions in the ISO and exit
  --no-copy         build only, do not touch the stick
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)      ISO="${2:?}"; shift 2 ;;
    --edition)  EDITION="${2:?}"; shift 2 ;;
    --size)     SIZE="${2:?}"; shift 2 ;;
    --block-size) BLOCK_SIZE="${2:?}"; shift 2 ;;
    --dest)     DEST_DIR="${2:?}"; shift 2 ;;
    --out)      OUT="${2:?}"; shift 2 ;;
    --ventoy)   VENTOY="${2:?}"; shift 2 ;;
    --list-editions) LIST_ONLY=1; shift ;;
    --no-copy)  NO_COPY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

need qemu-img qemu-nbd wimapply wiminfo mkntfs parted iconv base64 numfmt python3
[[ -n $ISO ]] || die "no ISO given; use --iso or create windows/win11.conf"
[[ -f $ISO ]] || die "ISO not found: $ISO"

# --- cleanup ------------------------------------------------------------------

MNT=""; NBD=""; ISO_MNT=""; ISO_LOOP=""; ISO_VIA=""
cleanup() {
  set +e
  [[ -n $MNT ]] && { sudo umount "$MNT" 2>/dev/null; rmdir "$MNT" 2>/dev/null; }
  [[ -n $NBD ]] && sudo qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
  [[ -n $ISO_MNT ]] && umount_iso
}
trap cleanup EXIT

# --- mount the ISO ------------------------------------------------------------

# Read-only and rootless where udisks allows it, so --list-editions needs no
# password. sudo is only taken once there is something to write.
log "Mounting $(basename "$ISO")"
mount_iso_ro "$ISO"

WIM="$ISO_MNT/sources/install.wim"
[[ -f $WIM ]] || die "no sources/install.wim in the ISO (an install.esd needs converting first)"
info "install.wim  $(human "$(stat -c%s "$WIM")")"

if (( LIST_ONLY )); then
  log "Editions in this ISO"
  wim_editions "$WIM" | awk -F'\t' '{ printf "    %2s  %s\n", $1, $2 }'
  exit 0
fi

[[ -n $EDITION ]] || die "no edition given; run with --list-editions first"

# Resolve the edition name to its WIM index.
INDEX=$(wim_editions "$WIM" | awk -F'\t' -v want="$EDITION" '$2 == want { print $1; exit }')
if [[ -z $INDEX ]]; then
  die "edition not found in this ISO: '$EDITION'
       this ISO contains:
$(wim_editions "$WIM" | awk -F'\t' '{ printf "         %2s  %s\n", $1, $2 }')"
fi
info "edition      $EDITION (index $INDEX)"

# --- password -----------------------------------------------------------------

read -rsp "    Password for local account '$USERNAME': " PW1; echo
read -rsp "    Repeat: " PW2; echo
[[ $PW1 == "$PW2" ]] || die "passwords do not match"
[[ -n $PW1 ]] || die "empty password; use a password or edit the template for a blank account"
PW_ENC=$(unattend_password "$PW1" "Password")
unset PW1 PW2

# --- build the VHDX -----------------------------------------------------------

# Everything from here writes: nbd, mkntfs and wimapply all need root.
sudo -v || die "sudo is required to build the image (nbd, mkntfs, wimapply)"

mkdir -p "$(dirname "$OUT")"
[[ -e $OUT ]] && { warn "overwriting existing $OUT"; rm -f "$OUT"; }

# block_size matters more than it looks. Left unset, qemu auto-calculates it
# from the virtual size -- 16 MiB for a 48 GiB image -- and every scattered NTFS
# write then claims a whole 16 MiB payload block. A ~14 GiB Windows install
# smeared across 16 MiB blocks produced a 42 GiB file; at 1 MiB it is 17 GiB for
# the same content. That difference is paid in full on the stick, because exFAT
# cannot store the holes.
log "Creating dynamic VHDX ($SIZE, ${BLOCK_SIZE} blocks)"
qemu-img create -f vhdx -o "subformat=dynamic,block_size=$BLOCK_SIZE" "$OUT" "$SIZE" >/dev/null
info "$OUT"

sudo modprobe nbd max_part=16

# A freshly loaded nbd module's devices are held open for a moment by udev's
# initial scan of them, and qemu-nbd's NBD_SET_SOCK ioctl then fails with
#     qemu-nbd: Failed to set NBD socket
# Settling udev first closes the window; trying each device in turn closes the
# rest of it, because "looks free" and "is free" are not the same thing for the
# first few hundred milliseconds after the module loads.
sudo udevadm settle 2>/dev/null || true

attach_nbd() {
  local dev sys attempt
  for attempt in 1 2 3; do
    for dev in /dev/nbd[0-9]*; do
      [[ -b $dev ]] || continue
      [[ $dev == *p[0-9]* ]] && continue      # a partition node, not a device
      sys="/sys/block/${dev##*/}"
      [[ -e "$sys/pid" ]] && continue         # already serving an image
      # Default to "busy" when the size cannot be read: an unreadable device is
      # not an available one.
      [[ $(cat "$sys/size" 2>/dev/null || echo 1) == 0 ]] || continue
      if sudo qemu-nbd --connect="$dev" -f vhdx "$OUT" 2>/dev/null; then
        NBD="$dev"
        return 0
      fi
    done
    warn "no nbd device accepted the image (attempt $attempt/3); retrying"
    sleep 2
  done
  return 1
}

log "Attaching $OUT to an nbd device"
attach_nbd || die "could not attach $OUT to any /dev/nbd device.
       Every /dev/nbd* is busy, or the nbd module is unavailable.
       Inspect:  ls -l /sys/block/nbd*/pid
       Clear a stale one:  sudo qemu-nbd --disconnect /dev/nbdN"
info "attached to $NBD"

# MBR, one active NTFS partition. Ventoy's BCD expects to find \Windows on a
# plain basic volume; an ESP or MSR here would never be read.
log "Partitioning (MBR, single active NTFS volume)"
sudo parted -s "$NBD" mklabel msdos
sudo parted -s "$NBD" mkpart primary ntfs 1MiB 100%
sudo parted -s "$NBD" set 1 boot on
sudo partprobe "$NBD" 2>/dev/null || true
sudo udevadm settle 2>/dev/null || true
PART="${NBD}p1"
# Same race at the other end: the partition node is created by udev, not by
# parted, so it can lag the command that caused it.
for _ in 1 2 3 4 5; do [[ -b $PART ]] && break; sleep 1; done
[[ -b $PART ]] || die "partition device did not appear: $PART"

# mkntfs normally reads the partition start, head count and sectors-per-track
# from geometry ioctls, which an nbd partition device does not answer. Left to
# itself it writes zeros into the NTFS BPB and warns:
#     "Windows will not be able to boot from this device."
# hidden_sectors is the one that matters: it must equal the partition's start
# LBA, because Windows uses it to locate the volume within the disk. 255/63 is
# the conventional legacy CHS geometry Windows itself writes for a large MBR
# disk.
PART_START=$(cat "/sys/class/block/${PART##*/}/start" 2>/dev/null || echo 2048)
info "partition starts at sector $PART_START"

log "Formatting NTFS"
sudo mkntfs --quick --label Windows \
    --partition-start "$PART_START" \
    --heads 255 --sectors-per-track 63 \
    "$PART" >/dev/null

# A zero here is silent until Windows refuses to boot months later, so check it
# rather than trusting the flags went in.
HID=$(sudo dd if="$PART" bs=1 skip=28 count=4 status=none | od -An -tu4 | tr -d ' ')
[[ $HID == "$PART_START" ]] ||
  die "NTFS BPB hidden_sectors is $HID, expected $PART_START - Windows would not boot"
info "BPB hidden_sectors $HID, heads 255, sectors/track 63"

# Apply straight to the volume, not to a mounted directory: wimlib's ntfs-3g
# backend is what preserves security descriptors, hard links, short names and
# reparse points. Applying into a mount loses all of that and Windows will not
# boot.
log "Applying $EDITION to the volume (this is the slow part, ~7.6 GB)"
sudo wimapply "$WIM" "$INDEX" "$PART"

log "Installing unattend.xml (local account, no Microsoft account)"
MNT=$(mktemp -d /tmp/bootmedia-vhdx.XXXXXX)
sudo mount -t ntfs-3g "$PART" "$MNT"
sudo mkdir -p "$MNT/Windows/Panther"
sed -e "s|@@USERNAME@@|$USERNAME|g" \
    -e "s|@@PASSWORD@@|$PW_ENC|g" \
    -e "s|@@COMPUTERNAME@@|$COMPUTERNAME|g" \
    -e "s|@@LOCALE@@|$LOCALE|g" \
    -e "s|@@INPUTLOCALE@@|$INPUTLOCALE|g" \
    -e "s|@@TIMEZONE@@|$TIMEZONE|g" \
    "$ROOT/windows/unattend/unattend.xml.tmpl" \
  | sudo tee "$MNT/Windows/Panther/unattend.xml" >/dev/null
info "account      $USERNAME (Administrators), computer $COMPUTERNAME"

# --- exclude the BCD sysprep module -------------------------------------------
#
# Ventoy owns the boot chain: bootmgr and the BCD come from
# ventoy_vhdboot.img, patched in RAM at boot. This VHDX therefore has no system
# partition and no BCD store - which is the whole point of the layout, but it
# breaks one thing.
#
# On first boot Windows runs setup.exe -newsetup (applying install.wim leaves
# HKLM\SYSTEM\Setup\CmdLine set, so the out-of-box Setup still runs even
# though Windows Setup never installed anything). Its specialize pass executes
# Microsoft-Windows-Sysprep-SpBcd, which opens the *system* BCD store to write
# boot configuration. With no system partition it fails:
#
#   SYSPRP BCD: Failed to get system partition. Status: c0000452
#   SYSPRP Sysprep_Specialize_Bcd: There was an error opening the system store.
#
# One failed module aborts the entire pass, and Setup reports
# "Windows could not configure Windows to run on this computer's hardware".
#
# Skipping it costs nothing here: Ventoy re-patches the BCD it supplies on every
# boot, so anything this module wrote would be discarded - and a BCD specialized
# for one machine would be wrong on the next one anyway, which is the point of a
# stick that moves between machines.
log "Excluding the BCD sysprep module (this layout has no system partition)"
SPEC="$MNT/Windows/System32/Sysprep/ActionFiles/Specialize.xml"
[[ -f $SPEC ]] || die "Specialize.xml not found at $SPEC"
sudo python3 - "$SPEC" <<'PYEOF'
import re, sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
pat = re.compile(
    r'<imaging exclude="">(?:(?!</imaging>).)*?'
    r'Microsoft-Windows-Sysprep-SpBcd.*?</imaging>', re.S)
out, n = pat.subn("", s)
if n == 0:
    sys.exit("no Microsoft-Windows-Sysprep-SpBcd blocks found in Specialize.xml")
open(path, "w", encoding="utf-8").write(out)
print(f"    removed {n} SpBcd block(s)")
PYEOF

USED=$(sudo df -B1 --output=used "$MNT" | tail -1 | tr -d ' ')
info "applied      $(human "$USED")"

sudo umount "$MNT"; rmdir "$MNT"; MNT=""
sudo qemu-nbd --disconnect "$NBD" >/dev/null; NBD=""

# ACTUAL is the apparent size: what a plain copy onto exFAT will cost. The
# allocated size is smaller here only because ext4 can hold the holes.
ACTUAL=$(stat -c%s "$OUT")
ALLOC=$(( $(stat -c%b "$OUT") * 512 ))
log "Built $(human "$ACTUAL") (virtual $SIZE, $(human "$ALLOC") actually allocated locally)"
info "the stick pays the full $(human "$ACTUAL") -- exFAT cannot store sparse holes"

(( NO_COPY )) && { info "--no-copy: stick untouched"; exit 0; }

# --- copy onto the Ventoy stick ----------------------------------------------

[[ -n $VENTOY ]] || VENTOY=$(find_ventoy) || die "no mounted partition labelled 'Ventoy'; plug the stick in or pass --ventoy"
[[ -d $VENTOY ]] || die "not a directory: $VENTOY"
log "Ventoy stick at $VENTOY"

VHDBOOT="$VENTOY/ventoy/ventoy_vhdboot.img"
[[ -f $VHDBOOT ]] || die "$VHDBOOT is missing - Ventoy cannot boot a VHD without it.
       Run: $ROOT/ventoy/fetch-vhdboot.sh"

AVAIL=$(free_bytes "$VENTOY")
info "free on stick $(human "$AVAIL"), image $(human "$ACTUAL")"
(( AVAIL > ACTUAL )) || die "not enough free space on the stick"

# A dynamic VHDX grows as Windows writes. If the stick runs out before the
# image reaches its virtual size, the filesystem inside it corrupts.
VIRT=$(numfmt --from=iec "${SIZE%B}")
HEADROOM=$(( AVAIL - ACTUAL ))
if (( VIRT > HEADROOM + ACTUAL )); then
  warn "the VHDX can grow to $(human "$VIRT") but only $(human "$AVAIL") is free on the stick."
  warn "Windows will believe it has $SIZE. Filling it past the free space will corrupt the image."
fi

mkdir -p "$VENTOY$DEST_DIR"
DEST="$VENTOY$DEST_DIR/$(basename "$OUT")"
log "Copying to $DEST"
# Nothing else on the stick is read or written - this is a plain file copy.
cp --sparse=never "$OUT" "$DEST.part"
sync
mv "$DEST.part" "$DEST"
sync

log "Done"
info "Boot the stick and pick $(basename "$OUT") from the Ventoy menu."
info "First boot runs OOBE unattended and lands on the desktop as '$USERNAME'."
