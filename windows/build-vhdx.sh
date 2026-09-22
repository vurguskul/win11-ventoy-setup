#!/usr/bin/env bash
#
# Build a fully deployed, natively-bootable Windows 11 VHDX for Ventoy.
#
# This runs INSIDE the container (docker/Dockerfile). windows/build.sh is the
# host side that starts it. Nothing here needs root, and nothing here touches a
# kernel block device: every filesystem is created and populated as a plain
# file.
#
# Why the image is deployed here rather than on the stick:
#
#   Ventoy boots a VHDX by loading ventoy_vhdboot.img into RAM, patching its
#   BCD to point at the VHDX, and chainloading it. bootmgr therefore comes from
#   a memdisk, and Windows sees the firmware boot device as
#   [multi(0)disk(0)cdrom(0)] with an empty NT path - there is no system
#   partition anywhere. Setup's out-of-box phase (setup.exe -newsetup, which
#   runs on first boot because applying a WIM leaves HKLM\SYSTEM\Setup\CmdLine
#   set) ends with CallBack_MungeBootEntries, which hard-requires one:
#
#     IBSLIB BFSVC: Failed to get partition name. Status = 0xc0000452
#     [Windows could not update the computer's boot configuration.]
#
#   0xc0000452 is STATUS_SYSTEM_DEVICE_NOT_FOUND. No partition layout inside
#   the image can satisfy it, because the device Windows is looking for is the
#   one the firmware booted from. So that phase must not run on the stick.
#
#   Instead it runs here, in QEMU, off the image's own ESP, where the boot
#   chain is ordinary: bcdboot writes a real BCD (phase "winpe"), Windows boots
#   natively and completes specialize + OOBE (phase "deploy"). By the time the
#   VHDX reaches the stick, Setup is finished and never runs again - so what
#   Ventoy's memdisk does or does not provide stops mattering.
#
# Why install.wim is applied directly instead of running Setup in a VM:
#
#   Applying the WIM never runs Setup's install phase, so there is no hardware
#   check and no TPM binding, and none of the usual LabConfig bypass keys are
#   needed. Only the out-of-box phase runs, and it runs without a TPM attached.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# Booting WinPE, and everything that goes into the disk it boots from, is
# shared with windows/repair-vhdx.sh.
# shellcheck source=../lib/winpe.sh
source "$ROOT/lib/winpe.sh"

# --- config -------------------------------------------------------------------

ISO=""; EDITION=""; SIZE="48G"; BLOCK_SIZE="1M"; DRIVERS=""
USERNAME="user"; COMPUTERNAME="WIN11-USB"
LOCALE="en-GB"; INPUTLOCALE="en-GB"; TIMEZONE="GMT Standard Time"
WORK="/work"; OUT=""
LIST_ONLY=0; STOP_AFTER=""; DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-2700}"; PW_STDIN=0
REUSE_DISK=0

usage() {
  cat <<'EOF'
usage: build-vhdx.sh [options]        (runs inside the build container)

  --iso PATH         Windows 11 ISO
  --edition NAME     edition to apply, e.g. "Windows 11 Pro"
  --size SIZE        virtual size of the VHDX (default 48G)
  --block-size SIZE  VHDX payload block size (default 1M)
  --drivers DIR      inject every INF package under DIR into the driver store
  --user NAME        local account to create
  --computer NAME    computer name
  --locale / --input-locale / --timezone
  --work DIR         working directory (default /work)
  --out PATH         final VHDX (default <work>/win11.vhdx)
  --list-editions    print the editions in the ISO and exit
  --stop-after STAGE stop after: extract|volumes|apply|assemble|winpe|deploy|verify
  --reuse-disk       keep the existing disk image and start at the winpe phase
  --password-stdin   read the encoded unattend password from stdin
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)          ISO="${2:?}"; shift 2 ;;
    --edition)      EDITION="${2:?}"; shift 2 ;;
    --size)         SIZE="${2:?}"; shift 2 ;;
    --block-size)   BLOCK_SIZE="${2:?}"; shift 2 ;;
    --drivers)      DRIVERS="${2:?}"; shift 2 ;;
    --user)         USERNAME="${2:?}"; shift 2 ;;
    --computer)     COMPUTERNAME="${2:?}"; shift 2 ;;
    --locale)       LOCALE="${2:?}"; shift 2 ;;
    --input-locale) INPUTLOCALE="${2:?}"; shift 2 ;;
    --timezone)     TIMEZONE="${2:?}"; shift 2 ;;
    --work)         WORK="${2:?}"; shift 2 ;;
    --out)          OUT="${2:?}"; shift 2 ;;
    --list-editions) LIST_ONLY=1; shift ;;
    --stop-after)   STOP_AFTER="${2:?}"; shift 2 ;;
    --reuse-disk)   REUSE_DISK=1; shift ;;
    --password-stdin) PW_STDIN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

OUT="${OUT:-$WORK/win11.vhdx}"
need 7z wimapply wimextract wiminfo wimupdate mkntfs ntfscat ntfscp ntfsls \
     sgdisk mkfs.vfat mcopy mmd mdir mtype qemu-img qemu-system-x86_64 python3

[[ -n $ISO && -f $ISO ]] || die "ISO not found: ${ISO:-<unset>}"
mkdir -p "$WORK"

OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
[[ -f $OVMF_CODE ]] || die "OVMF firmware missing at $OVMF_CODE"

SRC="$WORK/iso"            # what we pull out of the ISO
DISK="$WORK/disk.raw"      # the assembled disk, built and booted here
ESP_IMG="$WORK/esp.img"
NTFS_IMG="$WORK/ntfs.img"

stage_done() { [[ -n $STOP_AFTER && $STOP_AFTER == "$1" ]] && { log "--stop-after $1: stopping"; exit 0; }; return 0; }

# --- extract ------------------------------------------------------------------

# --list-editions needs install.wim and nothing else.
WIM=$(iso_extract "$ISO" "$SRC" $(( ! LIST_ONLY )))

if (( LIST_ONLY )); then
  log "Editions in this ISO"
  wim_editions "$WIM" | awk -F'\t' '{ printf "    %2s  %s\n", $1, $2 }'
  exit 0
fi
[[ -n $EDITION ]] || die "no edition given; run with --list-editions first"
INDEX=$(wim_editions "$WIM" | awk -F'\t' -v want="$EDITION" '$2 == want { print $1; exit }')
[[ -n $INDEX ]] || die "edition not found in this ISO: '$EDITION'
       this ISO contains:
$(wim_editions "$WIM" | awk -F'\t' '{ printf "         %2s  %s\n", $1, $2 }')"
info "edition      $EDITION (index $INDEX)"
stage_done extract

# --- password -----------------------------------------------------------------

PW_ENC=""
if (( PW_STDIN )); then
  IFS= read -r PW_ENC || true
  [[ -n $PW_ENC ]] || die "--password-stdin given but nothing was read"
fi

# --- volumes ------------------------------------------------------------------
#
# The GPT is written first so the partition offsets come from sgdisk rather
# than from arithmetic repeated in two places. mkntfs then gets the real start
# LBA: it normally reads that from geometry ioctls, which a plain file does not
# answer, and writes zeros into the BPB instead. hidden_sectors must equal the
# partition's start LBA or Windows cannot locate the volume within the disk.
if (( REUSE_DISK )); then
  [[ -f $DISK ]] || die "--reuse-disk given but there is no $DISK to reuse"
  log "Reusing the existing disk image"
  info "$DISK  $(human "$(stat -c%s "$DISK")")"
else
  log "Writing the GPT (ESP + MSR + Windows)"
  rm -f "$DISK"
  truncate -s "$SIZE" "$DISK"
  sgdisk -Z "$DISK" >/dev/null 2>&1 || true
  sgdisk -o \
    -n 1:2048:+300M -t 1:ef00 -c 1:ESP \
    -n 2:0:+16M     -t 2:0c01 -c 2:MSR \
    -n 3:0:0        -t 3:0700 -c 3:Windows \
    "$DISK" >/dev/null
fi

ESP_START=$(part_first 1 "$DISK");  ESP_SECTORS=$(( $(part_last 1 "$DISK") - ESP_START + 1 ))
WIN_START=$(part_first 3 "$DISK");  WIN_SECTORS=$(( $(part_last 3 "$DISK") - WIN_START + 1 ))
info "ESP      LBA $ESP_START  $(human $(( ESP_SECTORS * 512 )))"
info "Windows  LBA $WIN_START  $(human $(( WIN_SECTORS * 512 )))"

# Not indented: the bodies below carry here-documents, whose terminators have
# to sit at column 0.
if (( REUSE_DISK )); then
  info "skipping volumes, apply and assemble"
else
log "Formatting the ESP (FAT32)"
rm -f "$ESP_IMG"; truncate -s $(( ESP_SECTORS * 512 )) "$ESP_IMG"
mkfs.vfat -F 32 -n ESP "$ESP_IMG" >/dev/null

log "Formatting NTFS"
rm -f "$NTFS_IMG"; truncate -s $(( WIN_SECTORS * 512 )) "$NTFS_IMG"
mkntfs -F -Q -L Windows \
  --partition-start "$WIN_START" --heads 255 --sectors-per-track 63 \
  "$NTFS_IMG" >/dev/null

# A zero here is silent until Windows refuses to boot months later.
HID=$(dd if="$NTFS_IMG" bs=1 skip=28 count=4 status=none | od -An -tu4 | tr -d ' ')
[[ $HID == "$WIN_START" ]] ||
  die "NTFS BPB hidden_sectors is $HID, expected $WIN_START - Windows would not boot"
info "BPB hidden_sectors $HID, heads 255, sectors/track 63"
stage_done volumes

# --- apply --------------------------------------------------------------------

log "Rendering unattend.xml"
# The build's own shutdown is appended as the last first-logon command: OOBE
# runs here in QEMU, so the image has to put itself away when it is done. It
# runs once, during this build, and is spent by the time the stick sees it.
sed -e "s|@@USERNAME@@|$USERNAME|g" \
    -e "s|@@PASSWORD@@|$PW_ENC|g" \
    -e "s|@@COMPUTERNAME@@|$COMPUTERNAME|g" \
    -e "s|@@LOCALE@@|$LOCALE|g" \
    -e "s|@@INPUTLOCALE@@|$INPUTLOCALE|g" \
    -e "s|@@TIMEZONE@@|$TIMEZONE|g" \
    "$ROOT/windows/unattend/unattend.xml.tmpl" > "$WORK/unattend.xml"
# Checked by name, not by looking for "@@": the template documents its own
# placeholder syntax in a comment, and that comment is not a failure.
! grep -qE '@@(USERNAME|PASSWORD|COMPUTERNAME|LOCALE|INPUTLOCALE|TIMEZONE)@@' \
    "$WORK/unattend.xml" || die "unattend.xml still has unsubstituted placeholders"

# Injected into the WIM rather than copied in afterwards: ntfscp cannot create
# the directory, and \Windows\Panther may not exist in the image.
log "Injecting unattend.xml into the WIM"
# delete first: the extraction is cached, so on a re-run the WIM already has
# last run's unattend.xml in it and a bare add would fail.
# wimupdate takes a single --command; more than one has to arrive on stdin.
wimupdate "$WIM" "$INDEX" >/dev/null <<CMDS
delete --force /Windows/Panther/unattend.xml
add "$WORK/unattend.xml" "/Windows/Panther/unattend.xml"
CMDS
# It carries the encoded password; the copy inside the image is the only one
# that should outlive this line.
rm -f "$WORK/unattend.xml"

# Applied to the NTFS volume file, not to a mounted directory: wimlib's
# ntfs-3g backend is what preserves security descriptors, hard links, short
# names and reparse points, and it takes a regular file just as happily as a
# block device. Applying into a mountpoint loses all of that.
log "Applying $EDITION to the volume (the slow part, ~7.6 GB)"
wimapply "$WIM" "$INDEX" "$NTFS_IMG"
info "applied      $(human "$(stat -c%b "$NTFS_IMG" | awk '{print $1*512}')") allocated"
stage_done apply

# --- assemble -----------------------------------------------------------------

log "Assembling the disk image"
place "$ESP_IMG"  "$ESP_START" "$DISK"
place "$NTFS_IMG" "$WIN_START" "$DISK"
rm -f "$ESP_IMG" "$NTFS_IMG"
stage_done assemble
fi

# --- QEMU helpers -------------------------------------------------------------

qemu_accel
qmp_script

# mtools reads the ESP straight out of the assembled disk at its offset, so the
# build can check what the guest wrote there without mounting anything.
cat > "$WORK/mtoolsrc" <<EOF
drive s: file="$DISK" offset=$(( ESP_START * 512 ))
mtools_skip_check=1
EOF
export MTOOLSRC="$WORK/mtoolsrc"

# --- winpe: give the image a BCD ----------------------------------------------
#
# Windows cannot boot natively from an empty ESP, and bcdboot does not exist on
# Linux. Rather than author a BCD by hand with hivex, the build boots the
# image's own WinPE and lets Microsoft's tool write it. WinPE comes up from a
# disk of its own, so the image under construction is unambiguously disk 0.
log "Building the WinPE boot disk"
PE_IMG="$WORK/winpe.img"
winpe_build_disk "$PE_IMG" "$WIM" "$INDEX" "$SRC" "$ROOT/windows/winpe/startnet.cmd"

# --- drivers ------------------------------------------------------------------
#
# install.wim's only display driver is basicdisplay.inf. On real hardware that
# is the Microsoft Basic Display Adapter: one screen, stuck at whatever mode
# the firmware's GOP left behind, and no external output at all, because a
# framebuffer driver cannot drive the machine's other display pipes. The same
# goes for any other device the inbox set does not cover. Windows Update would
# fix it on a machine that has working networking, but that is not something
# the image can rely on, and it is not something this build can do offline.
#
# So vendor INF packages are put in the image's driver store here, offline,
# with DISM in the WinPE phase that is running anyway. They cost nothing until
# the hardware they match turns up - which is what makes this right for a stick
# that moves between machines: inject every machine's drivers, and each one
# binds where it belongs.
#
# A disk of its own, with a *basic data* partition rather than an ESP: WinPE
# does not assign drive letters to EFI System Partitions, so drivers carried on
# the WinPE disk would be unreachable without another diskpart dance. A basic
# data FAT32 volume is lettered automatically.
DRV_IMG=""
DRV_ARGS=()
if [[ -n $DRIVERS ]]; then
  [[ -d $DRIVERS ]] || die "--drivers: not a directory: $DRIVERS"
  mapfile -t INFS < <(find "$DRIVERS" -type f -iname '*.inf' | sort)
  (( ${#INFS[@]} )) || die "--drivers: no .inf file anywhere under $DRIVERS
       an INF package is a directory of files, not an installer .exe - see the
       README for how to get one out of a vendor download."

  log "Building the driver payload disk"
  DRV_IMG="$WORK/drivers.img"
  DRV_PART="$WORK/drivers-part.img"
  rm -f "$DRV_IMG" "$DRV_PART"
  # 96 MiB of slack: FAT32 needs a floor of its own, and mcopy needs somewhere
  # to put the directory entries.
  DRV_MB=$(( $(du -sm --apparent-size "$DRIVERS" | cut -f1) + 96 ))
  truncate -s "${DRV_MB}M" "$DRV_IMG"
  sgdisk -o -n 1:2048:0 -t 1:0700 -c 1:DRIVERS "$DRV_IMG" >/dev/null
  DRV_START=$(part_first 1 "$DRV_IMG")
  DRV_SECTORS=$(( $(part_last 1 "$DRV_IMG") - DRV_START + 1 ))
  truncate -s $(( DRV_SECTORS * 512 )) "$DRV_PART"
  mkfs.vfat -F 32 -n DRIVERS "$DRV_PART" >/dev/null
  mmd -i "$DRV_PART" ::/drivers
  mcopy -s -i "$DRV_PART" "$DRIVERS"/* ::/drivers/
  # startnet.cmd finds the payload by this file: it has to recognise the volume
  # by content, because the drive letter WinPE gives it is not knowable here.
  : > "$WORK/payload.tag"
  mcopy -i "$DRV_PART" "$WORK/payload.tag" ::/drivers/payload.tag
  rm -f "$WORK/payload.tag"
  place "$DRV_PART" "$DRV_START" "$DRV_IMG"
  rm -f "$DRV_PART"
  info "${#INFS[@]} INF package(s) from $DRIVERS, $(human $(( DRV_MB * 1048576 )))"
  for i in "${INFS[@]}"; do info "  ${i#"$DRIVERS"/}"; done
  DRV_ARGS=(
    -drive file="$DRV_IMG",format=raw,if=none,id=drv,cache=writeback
    -device ide-hd,drive=drv,bus=ahci.2
  )
else
  info "no drivers to inject - the image will use only Windows' inbox set"
fi

log "Running bcdboot in WinPE"
# bootindex decides which of the disks the firmware tries first: the image
# being built has no BCD yet, so without it the boot order is a coin toss. The
# driver disk gets no bootindex at all - it is never booted from.
# 3 GB rather than 2: the WinPE image is loaded into a RAM disk in its
# entirety, and DISM works above that.
run_qemu winpe 1800 -m 3072 -smp 2 \
  -drive file="$DISK",format=raw,if=none,id=hd,cache=writeback \
  -device ich9-ahci,id=ahci \
  -device ide-hd,drive=hd,bus=ahci.0,bootindex=1 \
  -drive file="$PE_IMG",format=raw,if=none,id=pe,cache=writeback \
  -device ide-hd,drive=pe,bus=ahci.1,bootindex=0 \
  "${DRV_ARGS[@]}"

if mdir s:/EFI/Microsoft/Boot >/dev/null 2>&1; then
  info "ESP now holds $(mdir -b s:/EFI/Microsoft/Boot 2>/dev/null | wc -l) boot files"
else
  mtype s:winpe.log 2>/dev/null | sed 's/^/    | /' || true
  die "the ESP has no \\EFI\\Microsoft\\Boot after the WinPE phase - bcdboot did not run.
       See $WORK/winpe-*.png and the log above."
fi
mtype s:winpe.log > "$WORK/winpe.log" 2>/dev/null || true
mtype s:dism.log  > "$WORK/dism.log"  2>/dev/null || true
grep -q 'bcdboot exit code: 0' "$WORK/winpe.log" 2>/dev/null ||
  warn "bcdboot did not report exit code 0 - see $WORK/winpe.log"

# A driver that silently failed to inject is the whole bug this exists to fix,
# and it would not show up again until the image is on real hardware - so the
# build fails here rather than shipping an image that boots to a basic display.
if [[ -n $DRV_IMG ]]; then
  if grep -q 'dism exit code: 0' "$WORK/winpe.log" 2>/dev/null; then
    info "drivers      added to the image's driver store"
  else
    sed -n '/driver payload/,$p' "$WORK/winpe.log" 2>/dev/null | sed 's/^/    | /' >&2
    die "DISM did not add the drivers.
       See $WORK/winpe.log and $WORK/dism.log."
  fi
fi

# bcdboot writes \EFI\Microsoft\Boot\bootmgfw.efi and a UEFI NVRAM entry
# pointing at it. The NVRAM entry is no use here: every phase gets a fresh copy
# of OVMF_VARS, so the deploy boot would start with no entry and fall back to
# the removable-media path - which bcdboot does not create. Copying bootmgfw
# there makes the image boot on its own firmware state, which is also what lets
# anyone boot the VHDX directly.
log "Installing the removable-media boot path"
mcopy -n -o "s:/EFI/Microsoft/Boot/bootmgfw.efi" "$WORK/bootx64.efi" ||
  die "bootmgfw.efi is not in the ESP after bcdboot"
mmd "s:/EFI/BOOT" >/dev/null 2>&1 || true
mcopy -o "$WORK/bootx64.efi" "s:/EFI/BOOT/BOOTX64.EFI" ||
  die "could not write \\EFI\\BOOT\\BOOTX64.EFI into the ESP"
rm -f "$WORK/bootx64.efi"
info "ESP: $(mdir -b s:/EFI/BOOT 2>/dev/null | tr -d '\r' | tr '\n' ' ')"

rm -f "$PE_IMG" ${DRV_IMG:+"$DRV_IMG"}
stage_done winpe

# --- deploy: let Setup finish, natively ---------------------------------------
#
# The image now boots on its own, so Setup's out-of-box phase runs with a real
# system partition: specialize succeeds, BFSVC can write boot entries, OOBE
# processes unattend.xml, and the last first-logon command powers the machine
# off. Windows reboots itself once in the middle; QEMU rides that out.
log "Deploying: running Setup's out-of-box phase in QEMU"
info "this takes several minutes and reboots once; watch $WORK/deploy-*.png"
run_qemu deploy "$DEPLOY_TIMEOUT" -m 4096 -smp 2 \
  -drive file="$DISK",format=raw,if=none,id=hd,cache=writeback \
  -device ich9-ahci,id=ahci \
  -device ide-hd,drive=hd,bus=ahci.0,bootindex=0
stage_done deploy

# --- verify -------------------------------------------------------------------
#
# The guest powering itself off is already a strong signal - the shutdown is
# the last first-logon command, so it only runs if OOBE got that far - but the
# Panther logs are what make a failure diagnosable, and they are worth carving
# the volume back out for.
log "Verifying the deployed image"
CARVE="$WORK/verify-ntfs.img"
trap 'rm -f "$CARVE"' EXIT
dd if="$DISK" of="$CARVE" bs=1M skip=$(( WIN_START * 512 / 1048576 )) \
   count=$(( (WIN_SECTORS * 512 + 1048575) / 1048576 )) conv=sparse status=none
# NTFS records its total sector count in the BPB and libntfs-3g refuses a
# volume file shorter than that, so trim the rounded-up tail back off.
truncate -s $(( WIN_SECTORS * 512 )) "$CARVE"

# Setup's logs are pulled out whatever happens: they are what made the previous
# two failures diagnosable, and they cost nothing to keep.
for f in setupact.log setuperr.log; do
  ntfscat "$CARVE" "/Windows/Panther/$f" > "$WORK/$f" 2>/dev/null || true
  ntfscat "$CARVE" "/Windows/Panther/UnattendGC/$f" > "$WORK/oobe-$f" 2>/dev/null || true
done

# The authoritative check. The profile directory is created when OOBE creates
# the account and the user first logs on - which is also what runs the
# shutdown that ended the deploy phase. IMAGE_STATE_COMPLETE is logged by
# whichever pass finishes last, so it is reported when found and not required.
fail=0
if ntfsls --path "/Users/$USERNAME" "$CARVE" >/dev/null 2>&1; then
  info "user profile   C:\\Users\\$USERNAME exists"
else
  warn "no C:\\Users\\$USERNAME - OOBE did not create the account"; fail=1
fi

if grep -qs 'IMAGE_STATE_COMPLETE' "$WORK/setupact.log" "$WORK/oobe-setupact.log"; then
  info "image state    IMAGE_STATE_COMPLETE"
else
  info "image state    not logged as complete (the profile check is what counts)"
fi

for f in "$WORK/setuperr.log" "$WORK/oobe-setuperr.log"; do
  [[ -s $f ]] || continue
  warn "$(basename "$f") is not empty:"
  sed 's/^/    | /' "$f" | head -12 >&2
done

rm -f "$CARVE"; trap - EXIT
(( fail == 0 )) || die "the image did not finish deploying; logs are in $WORK/"
stage_done verify

# --- convert ------------------------------------------------------------------
#
# block_size matters more than it looks. Left unset, qemu auto-calculates it
# from the virtual size -- 16 MiB for a 48 GiB image -- and every scattered
# NTFS extent then claims a whole 16 MiB payload block: a ~14 GiB install
# produced a 42 GiB file. At 1 MiB it is ~17 GiB for the same content, and the
# stick pays the full file size because exFAT cannot store sparse holes.
log "Converting to VHDX ($BLOCK_SIZE blocks)"
rm -f "$OUT"
qemu-img convert -f raw -O vhdx -o "subformat=dynamic,block_size=$BLOCK_SIZE" "$DISK" "$OUT"
rm -f "$DISK"

ACTUAL=$(stat -c%s "$OUT")
log "Built $(human "$ACTUAL") (virtual $SIZE)"
info "$OUT"
info "the stick pays the full $(human "$ACTUAL") -- exFAT cannot store sparse holes"
info "Setup is finished inside this image: it boots to the login screen."
