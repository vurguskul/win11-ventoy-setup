#!/usr/bin/env bash
#
# Copy the finished VHDX onto the Ventoy stick.
#
# This stays on the host rather than in the container: it is a plain file copy,
# and there is no reason to hand a container write access to a stick holding
# everything else you keep on it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

DEST_DIR="/ventoy"; VENTOY=""; SRC="$ROOT/out/win11.vhdx"; REPLACE=0
[[ -f $ROOT/windows/win11.conf ]] && source "$ROOT/windows/win11.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ventoy) VENTOY="${2:?}"; shift 2 ;;
    --dest)   DEST_DIR="${2:?}"; shift 2 ;;
    --src)    SRC="${2:?}"; shift 2 ;;
    --replace) REPLACE=1; shift ;;
    -h|--help) echo "usage: copy-to-stick.sh [--ventoy MP] [--dest DIR] [--src PATH] [--replace]"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f $SRC ]] || die "no image at $SRC - run 'make windows' first"

[[ -n $VENTOY ]] || VENTOY=$(find_ventoy) || die "no mounted partition labelled 'Ventoy'; plug the stick in or pass --ventoy"
[[ -d $VENTOY ]] || die "not a directory: $VENTOY"
log "Ventoy stick at $VENTOY"

VHDBOOT="$VENTOY/ventoy/ventoy_vhdboot.img"
[[ -f $VHDBOOT ]] || die "$VHDBOOT is missing - Ventoy cannot boot a VHD without it.
       Run: $ROOT/ventoy/fetch-vhdboot.sh"

mkdir -p "$VENTOY$DEST_DIR"
DEST="$VENTOY$DEST_DIR/$(basename "$SRC")"

# An image that is being replaced rather than added is deleted first. Without
# this the stick needs room for both copies at once, and a stick holding a
# 35 GB image rarely has another 35 GB spare - which is exactly the situation
# windows/repair.sh ends in. The file removed is the one this script wrote, and
# only when the caller asked for a replacement.
if (( REPLACE )) && [[ -f $DEST ]]; then
  log "Removing the image already on the stick"
  info "$DEST  $(human "$(stat -c%s "$DEST")")"
  rm -f "$DEST"
  sync
fi

ACTUAL=$(stat -c%s "$SRC")
AVAIL=$(free_bytes "$VENTOY")
info "free on stick $(human "$AVAIL"), image $(human "$ACTUAL")"
(( AVAIL > ACTUAL )) || die "not enough free space on the stick"

# A dynamic VHDX grows as Windows writes. If the stick runs out before the
# image reaches its virtual size, the filesystem inside it corrupts. SIZE comes
# from win11.conf rather than from the file's own header: reading the header
# would mean qemu-img, and the point of the container is that the host has no
# build tools.
if [[ -n ${SIZE:-} ]]; then
  VIRT=$(numfmt --from=iec "${SIZE%B}" 2>/dev/null || echo 0)
  if (( VIRT > AVAIL )); then
    warn "the VHDX can grow to $(human "$VIRT") but only $(human "$AVAIL") is free on the stick."
    warn "Windows believes it has $SIZE. Filling it past the free space will corrupt the image."
  fi
fi

log "Copying to $DEST"
# Nothing else on the stick is read or written - this is a plain file copy.
cp --sparse=never "$SRC" "$DEST.part"
sync
mv "$DEST.part" "$DEST"
sync

log "Done"
info "Boot the stick and pick $(basename "$SRC") from the Ventoy menu."
info "Setup already finished inside the image: it comes up at the login screen."
