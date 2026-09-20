#!/usr/bin/env bash
# Shared helpers for boot-media build scripts.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }

need() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) || die "missing tools: ${missing[*]}
       on Arch: sudo pacman -S --needed wimlib qemu-img ntfs-3g parted"
}

# Free bytes on the filesystem holding $1.
free_bytes() { df -B1 --output=avail "$1" | tail -1 | tr -d ' '; }

human() { numfmt --to=iec-i --suffix=B "$1"; }

# Encode a password the way unattend.xml wants it: base64 of UTF-16LE of
# (password + element name). Keeps the plaintext out of the rendered file.
# $1 = password, $2 = element name (Password | AdministratorPassword)
unattend_password() {
  printf '%s' "$1$2" | iconv -f UTF-8 -t UTF-16LE | base64 -w0
}

# Resolve the mountpoint of the Ventoy exFAT data partition, or empty.
find_ventoy() {
  local dev mp
  while read -r dev mp; do
    [[ -n $mp ]] || continue
    printf '%s\n' "$mp"
    return 0
  done < <(lsblk -rno NAME,MOUNTPOINT,LABEL | awk '$3=="Ventoy"{print "/dev/"$1, $2}')
  return 1
}

# Print the images in a WIM as "index<TAB>name".
#
# The single parser for wiminfo output: listing and name->index lookup must not
# drift apart. wiminfo prints "Name:<spaces><value>", and the value contains
# spaces itself, so strip the label textually rather than by awk field.
wim_editions() {
  wiminfo "$1" | awk '
    /^Index:[[:space:]]/ { idx = $NF }
    /^Name:[[:space:]]/ {
      line = $0
      sub(/^Name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      printf "%s\t%s\n", idx, line
    }'
}

# Mount an ISO read-only, preferring udisks so no password is needed. Sets
# ISO_LOOP, ISO_MNT and ISO_VIA; pair with umount_iso.
mount_iso_ro() {
  local iso=$1 out dev mp
  if command -v udisksctl >/dev/null 2>&1; then
    out=$(udisksctl loop-setup -r -f "$iso" 2>&1) || out=""
    dev=$(grep -o '/dev/loop[0-9]*' <<<"$out" | head -1)
    if [[ -n $dev ]]; then
      # udisks may auto-mount on loop-setup; either way the mountpoint is
      # whatever lsblk reports afterwards.
      udisksctl mount -b "$dev" >/dev/null 2>&1 || true
      mp=$(lsblk -no MOUNTPOINT "$dev" | awk 'NF{print; exit}')
      if [[ -n $mp ]]; then
        ISO_LOOP=$dev; ISO_MNT=$mp; ISO_VIA=udisks
        return 0
      fi
      udisksctl loop-delete -b "$dev" >/dev/null 2>&1 || true
    fi
  fi
  sudo -v || die "sudo is required to mount the ISO"
  ISO_MNT=$(mktemp -d "${TMPDIR:-/tmp}/bootmedia-iso.XXXXXX")
  ISO_LOOP=$(sudo losetup --find --show --read-only "$iso")
  sudo mount -o ro "$ISO_LOOP" "$ISO_MNT"
  ISO_VIA=sudo
}

umount_iso() {
  case "${ISO_VIA:-}" in
    udisks)
      udisksctl unmount -b "$ISO_LOOP" >/dev/null 2>&1 || true
      udisksctl loop-delete -b "$ISO_LOOP" >/dev/null 2>&1 || true ;;
    sudo)
      sudo umount "$ISO_MNT" 2>/dev/null || true
      rmdir "$ISO_MNT" 2>/dev/null || true
      sudo losetup -d "$ISO_LOOP" 2>/dev/null || true ;;
  esac
  ISO_MNT=""; ISO_LOOP=""; ISO_VIA=""
}
