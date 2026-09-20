#!/usr/bin/env bash
#
# Fetch ventoy_vhdboot.img and install it on the Ventoy stick.
#
# Ventoy does not ship this file: it is released separately at
# https://github.com/ventoy/vhdiso/releases. Without it, picking a VHD(X) in
# the Ventoy menu prints
#     "Please put the right ventoy_vhdboot.img file to the 1st partition"
# and nothing boots. It holds the bootmgr and BCD that Ventoy patches at boot
# time to point at the VHDX you selected.
#
# This writes exactly one file, <ventoy>/ventoy/ventoy_vhdboot.img, and touches
# nothing else on the stick.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

VENTOY="${1:-}"
REPO="ventoy/vhdiso"

need curl bsdtar

[[ -n $VENTOY ]] || VENTOY=$(find_ventoy) || die "no mounted partition labelled 'Ventoy'; pass the mountpoint as an argument"
[[ -d $VENTOY ]] || die "not a directory: $VENTOY"

DEST="$VENTOY/ventoy/ventoy_vhdboot.img"
if [[ -f $DEST ]]; then
  log "Already installed: $DEST ($(human "$(stat -c%s "$DEST")"))"
  exit 0
fi

log "Looking up the latest $REPO release"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -o 'https://github.com/[^"]*ventoy_vhdboot\.zip' | head -1)
[[ -n $URL ]] || die "could not find a ventoy_vhdboot.zip asset in the latest release"
info "$URL"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vhdboot.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

log "Downloading"
curl -fL --progress-bar -o "$TMP/vhdboot.zip" "$URL"

log "Extracting"
bsdtar -xf "$TMP/vhdboot.zip" -C "$TMP"
IMG=$(find "$TMP" -name 'ventoy_vhdboot.img' -print -quit)
[[ -n $IMG ]] || die "no ventoy_vhdboot.img inside the archive"

mkdir -p "$VENTOY/ventoy"
cp "$IMG" "$DEST.part"
sync
mv "$DEST.part" "$DEST"
sync

log "Installed $DEST ($(human "$(stat -c%s "$DEST")"))"
