#!/usr/bin/env bash
#
# Booting Windows' own tools in QEMU: the shared half of the build and the
# repair.
#
# Some things can only be done by Windows itself - bcdboot has no Linux
# equivalent, and DISM is the only thing that can service an offline image's
# component store. Both scripts therefore build a bootable WinPE disk, attach
# the image being worked on, and let a .cmd file do the work. Everything in
# here is what those two have in common.
#
# Sourced inside the build container, after lib/common.sh. run_qemu() reads
# WORK, ACCEL, OVMF_CODE, OVMF_VARS and QMP_PORT from the caller.

# dd rather than a loop device: partitions are built as separate files and
# written into the disk at their own offsets, which needs nothing privileged.
place() {   # place <image file> <start LBA> <disk file>
  local src=$1 off=$(( $2 * 512 )) dst=$3
  (( off % 1048576 == 0 )) || die "partition at LBA $2 is not MiB-aligned; dd seek would be wrong"
  dd if="$src" of="$dst" bs=1M seek=$(( off / 1048576 )) conv=notrunc,sparse status=none
  info "$(basename "$src") -> $(basename "$dst") +$(( off / 1048576 )) MiB"
}

# First and last sector of a partition, read back from the table rather than
# recomputed - the two must not be able to disagree.
part_first() { sgdisk -i "$1" "$2" | awk '/^First sector:/ { print $3; exit }'; }
part_last()  { sgdisk -i "$1" "$2" | awk '/^Last sector:/  { print $3; exit }'; }

# --- the ISO ------------------------------------------------------------------
#
# 7z rather than a loop mount, which would need privileges the container does
# not have - and rather than libarchive, which cannot read this ISO at all:
# install.wim is 7.6 GB, so it exists only in the UDF filesystem, outside
# ISO9660's 4 GB limit. bsdtar sees two entries; 7z sees the real tree.
# Cached in the work directory: this pulls ~8 GB out of the ISO, and a re-run
# or a later --list-editions wants the same files. Only what is actually
# missing is extracted, and it is staged in .part first so an interrupted 7z
# cannot leave a truncated install.wim behind looking like a good one.
#
# Prints the path to install.wim.
iso_extract() {   # iso_extract <iso> <dest dir> <want boot files: 0|1>
  local iso=$1 src=$2 want_boot=$3 wim
  local -a want=()
  # Everything this prints is progress, and the caller is capturing stdout for
  # the path alone.
  {
    [[ -n $(find_ci "$src" 'sources/install.wim') ]] || want+=("sources/install.wim")
    if (( want_boot )); then
      [[ -n $(find_ci "$src" 'efi/microsoft/boot/efisys.bin') ]] || want+=("efi" "boot")
    fi

    log "Extracting boot files and WIMs from $(basename "$iso")"
    if (( ${#want[@]} )); then
      info "extracting ${want[*]} - this takes a few minutes"
      rm -rf "$src.part"; mkdir -p "$src.part" "$src"
      7z x -y -bso0 -bsp0 -o"$src.part" "$iso" "${want[@]}" >/dev/null ||
        die "7z could not read $iso"
      # Hardlink rather than copy or move: instant, no second copy of 7.5 GB,
      # and it merges into whatever a previous run already extracted.
      cp -rlf "$src.part"/. "$src"/
      rm -rf "$src.part"
    else
      info "using the cached extraction in $src"
    fi
    wim="$(find_ci "$src" 'sources/install.wim')"
    [[ -n $wim ]] ||
      die "no sources/install.wim in the ISO (an install.esd needs converting first)"
    info "install.wim  $(human "$(stat -c%s "$wim")")"
  } >&2
  printf '%s\n' "$wim"
}

# --- the WinPE disk -----------------------------------------------------------
#
# A FAT32 disk image rather than an ISO. OVMF has no ISO9660 driver - it reads
# UDF and FAT only - so a plain xorriso ISO gives its boot option nothing to
# mount ("failed to start ... : No mapping"), and this xorriso cannot write UDF.
# A bare FAT32 volume is the one thing the firmware is certain to read, and it
# is what a bootable Windows USB stick is anyway.
#
# The WinPE is the image's own recovery environment, not the ISO's boot.wim.
# boot.wim's WinPE cannot service an offline image at all: DISM starts
# dismhost.exe, never gets its COM object back, and every /Image: command ends
# at
#
#   DismHostLib: Failed to create DismHostManager remote object (hr:0x80004002)
#   DISM.EXE: Could not load the image session. HRESULT=80004002
#
# which is "No such interface supported" on the console. It is the WinPE that
# is broken and not the image being serviced: "dism /image:X:\", pointed at
# WinPE's own RAM disk, fails the same way, as does every variation of scratch
# directory, and the two WIMs ship byte-identical DISM binaries on the same
# servicing stack. Winre.wim's DISM works. It is a WinPE like any other -
# startnet.cmd runs once winpeshl.ini is gone, and bcdboot, diskpart and
# wpeutil are all there - and it comes out of the same media as the image being
# serviced, so the tool always matches what it is working on.
winpe_build_disk() {   # winpe_build_disk <out img> <install.wim> <index> <iso src> <cmd file>
  local out=$1 wim=$2 index=$3 src=$4 cmd=$5
  local pe_src="$src/winre.wim" boot_wim="$WORK/pe-boot.wim"
  local part="$WORK/winpe-part.img" images i d

  if [[ ! -s $pe_src ]]; then
    info "extracting Winre.wim from the image"
    rm -f "$src/Winre.wim"
    wimextract "$wim" "$index" /Windows/System32/Recovery/Winre.wim \
      --dest-dir="$src" --no-acls >/dev/null 2>&1 ||
      die "no \\Windows\\System32\\Recovery\\Winre.wim in this edition - there is
       no WinPE to boot"
    mv "$src/Winre.wim" "$pe_src"
  fi
  info "winre.wim    $(human "$(stat -c%s "$pe_src")")"
  cp "$pe_src" "$boot_wim"

  images=$(wiminfo "$boot_wim" | awk '/^Image Count:/ { print $NF }')
  # winpeshl.ini is what launches the recovery shell instead of startnet.cmd, so
  # it goes; startnet.cmd already exists, so it is removed before being added
  # rather than added over.
  for i in $(seq 1 "${images:-1}"); do
    wimupdate "$boot_wim" "$i" >/dev/null <<CMDS
delete --force /Windows/System32/winpeshl.ini
delete --force /Windows/System32/startnet.cmd
add "$cmd" "/Windows/System32/startnet.cmd"
CMDS
  done
  wiminfo "$boot_wim" 1 --boot >/dev/null
  info "patched $images WinPE image(s) with $(basename "$cmd"); booting image 1 (WinRE)"

  # A GPT disk with one EFI System Partition, not a bare FAT volume: OVMF found
  # no boot option at all on a partitionless FAT disk. PartitionDxe -> ESP ->
  # FatDxe -> \EFI\BOOT\BOOTX64.EFI is the path the firmware is built around.
  rm -f "$out" "$part"
  truncate -s $(( $(stat -c%s "$boot_wim") / 1048576 + 320 ))M "$out"
  sgdisk -o -n 1:2048:0 -t 1:ef00 -c 1:WINPE "$out" >/dev/null
  local start sectors
  start=$(part_first 1 "$out")
  sectors=$(( $(part_last 1 "$out") - start + 1 ))
  truncate -s $(( sectors * 512 )) "$part"
  mkfs.vfat -F 32 -n WINPE "$part" >/dev/null

  for d in efi boot; do
    local from; from="$(find_ci "$src" "$d")"
    [[ -n $from ]] && mcopy -s -i "$part" "$from" ::/
  done
  mmd -i "$part" ::/sources >/dev/null 2>&1 || true
  mcopy -i "$part" "$boot_wim" ::/sources/boot.wim
  rm -f "$boot_wim"

  # The ISO's own \EFI\BOOT\BOOTX64.EFI is cdboot.efi, which prints
  # "Press any key to boot from CD or DVD......" and gives up when nobody does.
  # bootmgfw.efi is the same boot manager without the prompt; the WIM has one.
  wimextract "$wim" "$index" /Windows/Boot/EFI/bootmgfw.efi --dest-dir="$WORK" >/dev/null
  mcopy -o -i "$part" "$WORK/bootmgfw.efi" ::/EFI/BOOT/BOOTX64.EFI
  rm -f "$WORK/bootmgfw.efi"

  place "$part" "$start" "$out"
  rm -f "$part"
  info "$out  $(human "$(stat -c%s "$out")")"
}

# --- QEMU ---------------------------------------------------------------------

# Sets ACCEL for run_qemu.
qemu_accel() {
  if [[ -c /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=(-machine q35,accel=kvm -cpu host)
  else
    warn "/dev/kvm is not available - falling back to emulation, which is far slower"
    warn "pass --device /dev/kvm to docker run"
    ACCEL=(-machine q35 -cpu max)
  fi
}

# Writes the QMP client run_qemu uses for screenshots.
qmp_script() {
  cat > "$WORK/qmp.py" <<'PYEOF'
import json, socket, sys
port, out = int(sys.argv[1]), sys.argv[2]
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
except OSError as e:
    sys.exit(f"cannot reach QMP: {e}")
f = sock.makefile("rwb"); f.readline()
def cmd(o):
    f.write((json.dumps(o) + "\n").encode()); f.flush()
    while True:
        line = f.readline()
        if not line: sys.exit("QMP closed")
        m = json.loads(line)
        if "return" in m or "error" in m: return m
cmd({"execute": "qmp_capabilities"})
r = cmd({"execute": "screendump", "arguments": {"filename": out, "format": "png"}})
if "error" in r: sys.exit(r["error"].get("desc", "screendump failed"))
PYEOF
}

# Run QEMU in the background and wait for the guest to power itself off. Every
# phase ends that way - WinPE with wpeutil shutdown, the deploy phase with the
# last first-logon command - so a clean exit is the success signal, and a
# timeout is a hang. Screenshots go to the work directory every minute, which
# is the only way to see what a -display none guest is stuck on.
run_qemu() {   # run_qemu <label> <timeout seconds> <qemu args...>
  local label=$1 timeout=$2; shift 2
  local vars="$WORK/ovmf-vars-$label.fd"
  cp "$OVMF_VARS" "$vars"
  # Old screenshots from a previous run of the same phase are worse than none:
  # they look exactly like current ones while showing a failure already fixed.
  rm -f "$WORK/$label"-[0-9]*.png "$WORK/$label-timeout.png"

  qemu-system-x86_64 "${ACCEL[@]}" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$vars" \
    -net none -display none \
    -qmp "tcp:127.0.0.1:${QMP_PORT:-4444},server,nowait" \
    "$@" &
  local pid=$! waited=0
  info "qemu pid $pid, ${timeout}s budget"

  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout )); then
      python3 "$WORK/qmp.py" "${QMP_PORT:-4444}" "$WORK/$label-timeout.png" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      die "$label phase did not finish within ${timeout}s
       last screen: $WORK/$label-timeout.png"
    fi
    sleep 10; waited=$(( waited + 10 ))
    if (( waited % 60 == 0 )); then
      python3 "$WORK/qmp.py" "${QMP_PORT:-4444}" "$WORK/$label-$(printf '%04d' "$waited").png" 2>/dev/null || true
      info "  $label: ${waited}s elapsed"
    fi
  done
  wait "$pid" 2>/dev/null || true
  info "$label phase finished after ${waited}s"
}
