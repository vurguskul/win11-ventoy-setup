#!/usr/bin/env bash
#
# Boot the real Ventoy stick in QEMU to verify the VHDX actually boots, without
# rebooting this machine.
#
# This exercises the whole chain - Ventoy's grub, vt_patch_vhdboot, the patched
# BCD, winload - which is the only way to be sure. Booting the VHDX on its own
# would fail by design: it contains no bootmgr, because Ventoy supplies it.
#
# Runs with -snapshot, so every write goes to a throwaway overlay and the stick
# is never modified. UEFI vars are a scratch copy for the same reason.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DISK="${1:-}"
MEM="${MEM:-4096}"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

need qemu-system-x86_64
[[ -f $OVMF_CODE ]] || die "OVMF firmware not found at $OVMF_CODE (pacman -S edk2-ovmf)"

if [[ -z $DISK ]]; then
  # Resolve by filesystem label rather than by mountpoint. find_ventoy() returns
  # a mountpoint, which is right for the scripts that copy files onto the stick
  # but backwards here: this script unmounts the stick as its first act, so
  # requiring it to be mounted in order to be found made it refuse to run in
  # exactly the state it wants.
  VPART=$(blkid -L Ventoy 2>/dev/null) || true
  [[ -n $VPART ]] || die "no partition labelled 'Ventoy' found; plug the stick in, or pass the disk device, e.g. /dev/sda"
  DISK="/dev/$(lsblk -nro PKNAME "$VPART" | head -1)"
fi
[[ -b $DISK ]] || die "not a block device: $DISK"

# The host has the exFAT partition mounted read-write. QEMU only reads it here
# (-snapshot), but a mounted-and-being-read filesystem can still hand the guest
# a half-written state, so unmount first.
if findmnt -nr -S "${DISK}1" >/dev/null 2>&1; then
  warn "${DISK}1 is mounted on the host; unmounting it for a clean test"
  udisksctl unmount -b "${DISK}1" >/dev/null || die "could not unmount ${DISK}1"
fi

VARS=$(mktemp "${TMPDIR:-/tmp}/ovmf-vars.XXXXXX.fd")
cp "$OVMF_VARS" "$VARS"
trap 'rm -f "$VARS"' EXIT

# Arch ships QEMU's UI backends as separate packages (qemu-ui-gtk and friends),
# and a stock qemu-base install has none of them, so `-display gtk` dies with
#     Display 'gtk' is not available.
# VNC is compiled into the qemu-system binary and needs no extra package. It
# also sidesteps a second problem that would bite even with qemu-ui-gtk
# installed: this runs under sudo, and sudo strips WAYLAND_DISPLAY and
# XDG_RUNTIME_DIR, so a GTK window has no display to attach to on a Wayland
# session. With VNC, QEMU runs as root and you connect as yourself.
DISPLAY_MODE="${DISPLAY_MODE:-vnc}"
if [[ $DISPLAY_MODE != vnc ]]; then
  qemu-system-x86_64 -display help 2>/dev/null | grep -qw -- "$DISPLAY_MODE" ||
    die "QEMU has no '$DISPLAY_MODE' display backend.
       Install it (pacman -S qemu-ui-$DISPLAY_MODE), or leave DISPLAY_MODE unset to use VNC."
fi

QEMU_ARGS=(
  -machine q35,accel=kvm
  -cpu host
  -m "$MEM"
  -smp 2
  -snapshot
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
  -drive if=pflash,format=raw,file="$VARS"
  -drive file="$DISK",format=raw,if=none,id=stick
  -device usb-ehci,id=ehci
  -device usb-storage,bus=ehci.0,drive=stick
  -vga std
  # QMP on loopback, so a -display none VM can still be inspected: screendump
  # grabs the framebuffer, which is the only way to see what it is doing
  # without a viewer attached.
  -qmp "tcp:127.0.0.1:${QMP_PORT:-4444},server,nowait"
)

if [[ $DISPLAY_MODE == vnc ]]; then
  # Pick a free display so a second run does not collide with a first one that
  # is still open.
  VNC_DISP=""
  for d in 0 1 2 3 4 5; do
    ss -ltn 2>/dev/null | grep -q ":$((5900 + d))\b" || { VNC_DISP=$d; break; }
  done
  [[ -n $VNC_DISP ]] || die "no free VNC display between 5900 and 5905"

  log "Booting $DISK in QEMU (snapshot mode - the stick is not written)"
  sudo qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -display none -vnc "127.0.0.1:$VNC_DISP" -daemonize

  info "QEMU is running in the background"
  info "connect:  vncviewer 127.0.0.1:$((5900 + VNC_DISP))"
  info "screenshot: windows/screenshot.sh   (no viewer needed)"
  info "stop:     sudo pkill -f 'qemu-system-x86_64.*id=stick'"
else
  log "Booting $DISK in QEMU (snapshot mode - the stick is not written)"
  info "close the window or press Ctrl-Alt-Q to stop"
  exec sudo qemu-system-x86_64 "${QEMU_ARGS[@]}" -display "$DISPLAY_MODE"
fi
