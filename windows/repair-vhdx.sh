#!/usr/bin/env bash
#
# Repair a VHDX that Windows Update has left unbootable, offline.
#
# This runs INSIDE the build container (docker/Dockerfile); windows/repair.sh
# is the host side that starts it. Like the build, it needs no root and no
# kernel block device: QEMU opens the VHDX as a plain file.
#
# The failure it exists for:
#
#   Windows Update offers a vendor BIOS update - HP's, in the case that
#   prompted this - as a driver in the Firmware device class. Installing one
#   stages a UEFI capsule on the system partition and asks the firmware to
#   flash it on the next boot. An image booted by Ventoy has no system
#   partition: bootmgr and the BCD come from a memdisk, and Windows sees the
#   firmware boot device as a cdrom with an empty NT path. The update can
#   therefore never complete, and every boot replays it - "Undoing changes made
#   to your computer", restart, again.
#
# Nothing here is specific to that one update: what the WinRE script does is
# back out whatever servicing operation is pending, and then stop the firmware
# class from being installed again. windows/unattend/unattend.xml.tmpl writes
# the same policy at build time, so images built after this one never get here.
#
# The image is attached to a QEMU guest that boots the *same* Windows' recovery
# environment, because DISM is the only thing that can service an offline
# component store, and it does not exist on Linux.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/winpe.sh
source "$ROOT/lib/winpe.sh"

VHDX=""; ISO=""; EDITION=""; WORK="/work"
REPAIR_TIMEOUT="${REPAIR_TIMEOUT:-1800}"

usage() {
  cat <<'EOF'
usage: repair-vhdx.sh --vhdx PATH --iso PATH [options]   (runs in the container)

  --vhdx PATH        the VHDX to repair, in place
  --iso PATH         Windows 11 ISO - the WinPE that does the work comes from it
  --edition NAME     edition to take the WinPE from (default: the first image)
  --work DIR         working directory (default /work)
  --timeout SECONDS  budget for the WinRE phase (default 1800)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vhdx)    VHDX="${2:?}"; shift 2 ;;
    --iso)     ISO="${2:?}"; shift 2 ;;
    --edition) EDITION="${2:?}"; shift 2 ;;
    --work)    WORK="${2:?}"; shift 2 ;;
    --timeout) REPAIR_TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

need 7z wimextract wiminfo wimupdate sgdisk mkfs.vfat mcopy mmd mdir mtype \
     qemu-img qemu-system-x86_64 python3
[[ -n $VHDX && -f $VHDX ]] || die "VHDX not found: ${VHDX:-<unset>}"
[[ -w $VHDX ]] || die "no write access to $VHDX"
[[ -n $ISO && -f $ISO ]] || die "ISO not found: ${ISO:-<unset>}"
mkdir -p "$WORK"

OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
[[ -f $OVMF_CODE ]] || die "OVMF firmware missing at $OVMF_CODE"

SRC="$WORK/iso"            # the same cached extraction the build uses
PE_IMG="$WORK/repair-pe.img"
RES_IMG="$WORK/repair-results.img"

# qemu-img refuses a VHDX it cannot parse, which is the one check worth doing
# before a guest starts writing to it.
log "Checking $VHDX"
qemu-img info -f vhdx "$VHDX" | sed 's/^/    /' ||
  die "qemu-img cannot read $VHDX as a VHDX"

# --- the WinPE that does the work ---------------------------------------------

WIM=$(iso_extract "$ISO" "$SRC" 1)
INDEX=1
if [[ -n $EDITION ]]; then
  INDEX=$(wim_editions "$WIM" | awk -F'\t' -v want="$EDITION" '$2 == want { print $1; exit }')
  [[ -n $INDEX ]] || die "edition not found in this ISO: '$EDITION'"
fi
info "WinPE from index $INDEX${EDITION:+ ($EDITION)}"

log "Building the WinRE boot disk"
winpe_build_disk "$PE_IMG" "$WIM" "$INDEX" "$SRC" "$ROOT/windows/winpe/repair.cmd"

# --- the results disk ---------------------------------------------------------
#
# A disk of its own with a *basic data* partition, for the same reason the
# build's driver payload has one: WinPE letters basic data volumes and does not
# letter EFI System Partitions, so this is the one place the WinRE script can
# reliably write to. It is how the log gets back out - the host reads this FAT
# volume with mtools, mounting nothing.
log "Building the results disk"
RES_PART="$WORK/repair-results-part.img"
rm -f "$RES_IMG" "$RES_PART"
truncate -s 64M "$RES_IMG"
sgdisk -o -n 1:2048:0 -t 1:0700 -c 1:REPAIR "$RES_IMG" >/dev/null
RES_START=$(part_first 1 "$RES_IMG")
RES_SECTORS=$(( $(part_last 1 "$RES_IMG") - RES_START + 1 ))
truncate -s $(( RES_SECTORS * 512 )) "$RES_PART"
mkfs.vfat -F 32 -n REPAIR "$RES_PART" >/dev/null
mmd -i "$RES_PART" ::/repair
: > "$WORK/payload.tag"
mcopy -i "$RES_PART" "$WORK/payload.tag" ::/repair/payload.tag
rm -f "$WORK/payload.tag"
place "$RES_PART" "$RES_START" "$RES_IMG"
rm -f "$RES_PART"

# mtools reads the volume straight out of the disk image at its offset, so the
# log comes back without mounting anything.
cat > "$WORK/repair-mtoolsrc" <<EOF
drive r: file="$RES_IMG" offset=$(( RES_START * 512 ))
mtools_skip_check=1
EOF
export MTOOLSRC="$WORK/repair-mtoolsrc"

# --- run it -------------------------------------------------------------------

qemu_accel
qmp_script

log "Booting WinRE against the image"
info "this takes a few minutes; watch $WORK/repair-*.png"
# The image is attached as a VHDX, not converted: QEMU writes VHDX in place,
# and a round trip through raw would mean twice the image's size in free space
# and two long copies. bootindex keeps the firmware on the WinRE disk - the
# image under repair must not be booted, which is the whole problem.
run_qemu repair "$REPAIR_TIMEOUT" -m 3072 -smp 2 \
  -drive file="$VHDX",format=vhdx,if=none,id=hd,cache=writeback \
  -device ich9-ahci,id=ahci \
  -device ide-hd,drive=hd,bus=ahci.0,bootindex=1 \
  -drive file="$PE_IMG",format=raw,if=none,id=pe,cache=writeback \
  -device ide-hd,drive=pe,bus=ahci.1,bootindex=0 \
  -drive file="$RES_IMG",format=raw,if=none,id=res,cache=writeback \
  -device ide-hd,drive=res,bus=ahci.2

# --- what happened ------------------------------------------------------------

mtype r:/repair/repair.log > "$WORK/repair.log" 2>/dev/null || true
mtype r:/repair/dism.log   > "$WORK/repair-dism.log" 2>/dev/null || true
[[ -s $WORK/repair.log ]] ||
  die "the WinRE phase wrote no log - it did not get as far as running.
       See $WORK/repair-*.png."

log "What the repair did"
grep -vE '^(Deployment Image|Version:|Image Version:|\[=|$)' "$WORK/repair.log" |
  sed 's/\r$//; s/^/    | /'

rm -f "$PE_IMG" "$RES_IMG"

grep -q 'repair finished' "$WORK/repair.log" ||
  die "the WinRE script did not run to the end; full log in $WORK/repair.log"

# revertpendingactions reports 0x800f082f when there was nothing pending, which
# is exactly what a repaired image says - so it is reported, not failed on.
if grep -q 'pending.xml is still there' "$WORK/repair.log"; then
  warn "pending.xml survived the revert: the image may still replay the update"
fi

log "Repaired $VHDX"
info "full log: $WORK/repair.log (DISM's own: $WORK/repair-dism.log)"
