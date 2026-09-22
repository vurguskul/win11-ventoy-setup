#!/usr/bin/env bash
#
# Host side of the repair: recover a VHDX that will no longer boot because
# Windows Update left an update half-installed - a vendor BIOS update, in the
# case this was written for.
#
# By default it works on a copy:
#
#   stick -> out/rescue/win11.vhdx -> repaired there -> copied back on request
#
# The copy is the point. The repair boots WinRE against the image and lets DISM
# write to it, and an image that is already failing is not one to experiment on
# without a way back: the copy is what gets repaired, and until the last step
# the stick still holds exactly what it held before.
#
# --in-place skips all that and repairs the file where it lies, which is the
# right thing for a local build and the wrong thing for the only copy you have.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

IMAGE="${IMAGE:-win11-ventoy-build}"
ISO=""; EDITION=""; DEST_DIR="/ventoy"
VHDX=""; VENTOY=""; IN_PLACE=0; REFRESH=0; YES=0
RESCUE_DIR="$ROOT/out/rescue"

[[ -f $ROOT/windows/win11.conf ]] && source "$ROOT/windows/win11.conf"

usage() {
  cat <<'EOF'
usage: repair.sh [options]

  --vhdx PATH    image to repair (default: the one on the Ventoy stick)
  --ventoy MP    Ventoy mountpoint, if it cannot be found automatically
  --dest DIR     directory on the stick holding the image (default /ventoy)
  --iso PATH     Windows ISO to take the WinPE from (default: win11.conf)
  --edition NAME edition to take the WinPE from (default: win11.conf)
  --in-place     repair the file where it is, with no copy and no way back
  --refresh      re-copy from the stick even if out/rescue/ already has a copy
  --yes          do not ask before copying the repaired image back
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vhdx)    VHDX="${2:?}"; shift 2 ;;
    --ventoy)  VENTOY="${2:?}"; shift 2 ;;
    --dest)    DEST_DIR="${2:?}"; shift 2 ;;
    --iso)     ISO="${2:?}"; shift 2 ;;
    --edition) EDITION="${2:?}"; shift 2 ;;
    --in-place) IN_PLACE=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    --yes|-y)  YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

need docker
[[ -n $ISO ]] || die "no ISO given; use --iso or create windows/win11.conf"
[[ -f $ISO ]] || die "ISO not found: $ISO"

# --- what to repair -----------------------------------------------------------

ON_STICK=0
if [[ -z $VHDX ]]; then
  [[ -n $VENTOY ]] || VENTOY=$(find_ventoy) ||
    die "no mounted partition labelled 'Ventoy'; plug the stick in, or pass --vhdx"
  VHDX="$VENTOY$DEST_DIR/win11.vhdx"
  [[ -f $VHDX ]] || die "no image at $VHDX"
  ON_STICK=1
fi
[[ -f $VHDX ]] || die "no such file: $VHDX"
log "Image to repair: $VHDX ($(human "$(stat -c%s "$VHDX")"))"

TARGET="$VHDX"
if (( ON_STICK && ! IN_PLACE )); then
  mkdir -p "$RESCUE_DIR"
  TARGET="$RESCUE_DIR/$(basename "$VHDX")"
  SIZE_B=$(stat -c%s "$VHDX")
  if [[ -f $TARGET ]] && ! (( REFRESH )); then
    log "Reusing the copy already in $RESCUE_DIR"
    info "$(human "$(stat -c%s "$TARGET")"), copied $(date -r "$TARGET" '+%Y-%m-%d %H:%M')"
    info "pass --refresh to take a fresh copy from the stick"
  else
    AVAIL=$(free_bytes "$RESCUE_DIR")
    (( AVAIL > SIZE_B )) ||
      die "need $(human "$SIZE_B") free for the copy, $RESCUE_DIR has $(human "$AVAIL")"
    log "Copying the image off the stick first"
    info "$(human "$SIZE_B") over USB - this is the slow part"
    # .part first: an interrupted copy must not be mistaken for a good one by
    # the next run.
    rm -f "$TARGET.part"
    cp --sparse=never "$VHDX" "$TARGET.part"
    sync
    mv "$TARGET.part" "$TARGET"
  fi
elif (( IN_PLACE )); then
  warn "repairing in place: there is no second copy of this image"
fi

# --- run the repair in the container -----------------------------------------

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  log "Building the $IMAGE container image"
  docker build -t "$IMAGE" -f "$ROOT/docker/Dockerfile" "$ROOT/docker"
}

ISO_DIR="$(cd "$(dirname "$ISO")" && pwd)"; ISO_NAME="$(basename "$ISO")"
TARGET_DIR="$(cd "$(dirname "$TARGET")" && pwd)"; TARGET_NAME="$(basename "$TARGET")"

DOCKER_ARGS=(
  --rm -i
  --user "$(id -u):$(id -g)"
  -v "$ROOT:/repo:ro"
  -v "$ISO_DIR:/iso:ro"
  -v "$ROOT/out:/work"
  # The image being repaired is mounted separately: it may be on the stick, and
  # then it is not under out/ at all.
  -v "$TARGET_DIR:/target"
)
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  DOCKER_ARGS+=(--device /dev/kvm)
else
  warn "/dev/kvm is not readable by you; the WinRE phase will be very slow"
fi

mkdir -p "$ROOT/out"
CMD=(/repo/windows/repair-vhdx.sh --vhdx "/target/$TARGET_NAME" --iso "/iso/$ISO_NAME")
[[ -n $EDITION ]] && CMD+=(--edition "$EDITION")

log "Starting the repair container"
docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${CMD[@]}"

# --- back to the stick --------------------------------------------------------

if [[ $TARGET == "$VHDX" ]]; then
  log "Done - $VHDX was repaired in place"
  exit 0
fi

log "The repaired image is at $TARGET"
info "the stick still holds the unrepaired one until it is replaced"
info "windows/test-boot.sh boots the stick, so it can only check the image once"
info "it is back there - the copy below is what makes that safe to try"

if ! (( YES )); then
  if [[ ! -t 0 ]]; then
    info "to put it back:  windows/copy-to-stick.sh --src '$TARGET' --replace"
    exit 0
  fi
  read -rp "    Copy it back to the stick now, replacing $VHDX? [y/N] " ans
  [[ ${ans,,} == y* ]] || {
    info "left alone; when you want it there:"
    info "  windows/copy-to-stick.sh --src '$TARGET' --replace"
    exit 0
  }
fi

COPY_ARGS=(--src "$TARGET" --dest "$DEST_DIR" --replace)
[[ -n $VENTOY ]] && COPY_ARGS+=(--ventoy "$VENTOY")
"$ROOT/windows/copy-to-stick.sh" "${COPY_ARGS[@]}"
info "the repaired image is still in $RESCUE_DIR too; delete it once the stick boots"
