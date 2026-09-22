#!/usr/bin/env bash
#
# Host side of the Windows 11 build: prepare inputs, then run the pipeline in
# the container.
#
# The host needs docker and /dev/kvm and nothing else - no wimlib, no ntfs-3g,
# no qemu, no root. windows/build-vhdx.sh does the work inside
# docker/Dockerfile's image, as your own uid, on plain files.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

IMAGE="${IMAGE:-win11-ventoy-build}"

# Defaults live in the container script; anything set here - by win11.conf or
# on the command line - is passed to it explicitly. Leaving a value unset and
# relying on the two sides agreeing on a default is how EDITION silently failed
# to arrive.
ISO=""; EDITION=""; SIZE=""; BLOCK_SIZE=""; USERNAME="egor"; COMPUTERNAME=""
LOCALE=""; INPUTLOCALE=""; TIMEZONE=""; LIST_ONLY=0
DRIVERS_DIR=""
PASS_THROUGH=()

[[ -f $ROOT/windows/win11.conf ]] && source "$ROOT/windows/win11.conf"

# Asking for drivers and getting none silently is worse than a hard stop, so
# the two cases are told apart: an explicit DRIVERS_DIR that yields nothing is
# an error, the default directory being empty is not.
DRIVERS_EXPLICIT=0; [[ -n $DRIVERS_DIR ]] && DRIVERS_EXPLICIT=1

# Command-line arguments override win11.conf. Anything not recognised here is
# handed to the container script unchanged.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)          ISO="${2:?}"; shift 2 ;;
    --edition)      EDITION="${2:?}"; shift 2 ;;
    --size)         SIZE="${2:?}"; shift 2 ;;
    --block-size)   BLOCK_SIZE="${2:?}"; shift 2 ;;
    --drivers)      DRIVERS_DIR="${2:?}"; DRIVERS_EXPLICIT=1; shift 2 ;;
    --user)         USERNAME="${2:?}"; shift 2 ;;
    --computer)     COMPUTERNAME="${2:?}"; shift 2 ;;
    --locale)       LOCALE="${2:?}"; shift 2 ;;
    --input-locale) INPUTLOCALE="${2:?}"; shift 2 ;;
    --timezone)     TIMEZONE="${2:?}"; shift 2 ;;
    --list-editions) LIST_ONLY=1; shift ;;
    *) PASS_THROUGH+=("$1"); shift ;;
  esac
done

need docker
[[ -n $ISO ]] || die "no ISO given; use --iso or create windows/win11.conf"
[[ -f $ISO ]] || die "ISO not found: $ISO"
ISO_DIR="$(cd "$(dirname "$ISO")" && pwd)"
ISO_NAME="$(basename "$ISO")"

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  log "Building the $IMAGE container image"
  docker build -t "$IMAGE" -f "$ROOT/docker/Dockerfile" "$ROOT/docker"
}

DOCKER_ARGS=(
  --rm -i
  --user "$(id -u):$(id -g)"
  -v "$ROOT:/repo:ro"
  -v "$ISO_DIR:/iso:ro"
  -v "$ROOT/out:/work"
)

# KVM is not strictly required - qemu falls back to emulation - but Setup's
# out-of-box phase under TCG takes hours rather than minutes.
if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  DOCKER_ARGS+=(--device /dev/kvm)
else
  warn "/dev/kvm is not readable by you; the deploy phase will be very slow"
  warn "on Arch: add yourself to the kvm group, or check the device permissions"
fi

mkdir -p "$ROOT/out"

CMD=("/repo/windows/build-vhdx.sh" --iso "/iso/$ISO_NAME")
opt() { [[ -n $2 ]] && CMD+=("$1" "$2"); return 0; }
opt --edition      "$EDITION"
opt --size         "$SIZE"
opt --block-size   "$BLOCK_SIZE"
opt --user         "$USERNAME"
opt --computer     "$COMPUTERNAME"
opt --locale       "$LOCALE"
opt --input-locale "$INPUTLOCALE"
opt --timezone     "$TIMEZONE"

# Vendor INF packages to put in the image's driver store. Windows' inbox set
# has no driver for any modern GPU, and an image built and deployed entirely
# inside QEMU has never seen the machine it will run on - so without this it
# comes up on the Microsoft Basic Display Adapter: wrong resolution, and no
# external monitor. The directory is bind-mounted rather than passed by path:
# the container only has /repo and /iso, and drivers may live outside both.
DRIVERS_DIR="${DRIVERS_DIR:-$ROOT/windows/drivers}"
# Resolved against the repo, not the shell's cwd: win11.conf is a config file,
# and a relative path in one should not mean something different depending on
# where make was run from.
[[ $DRIVERS_DIR == /* ]] || DRIVERS_DIR="$ROOT/$DRIVERS_DIR"
if [[ -d $DRIVERS_DIR ]] && [[ -n $(find "$DRIVERS_DIR" -type f -iname '*.inf' -print -quit) ]]; then
  DRIVERS_ABS="$(cd "$DRIVERS_DIR" && pwd)"
  DOCKER_ARGS+=(-v "$DRIVERS_ABS:/drivers:ro")
  CMD+=(--drivers /drivers)
  info "drivers from $DRIVERS_ABS"
elif (( DRIVERS_EXPLICIT )); then
  die "no .inf file anywhere under $DRIVERS_DIR
       an INF package is a directory of files, not an installer .exe - see the
       README for how to get one out of a vendor download."
fi

(( ${#PASS_THROUGH[@]} )) && CMD+=("${PASS_THROUGH[@]}")

# --list-editions needs no password and no config beyond the ISO.
if (( LIST_ONLY )); then
  exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${CMD[@]}" --list-editions
fi

[[ -n $EDITION ]] || die "no edition given; run 'make list-editions' first"

# The password is encoded here and handed over on stdin. It never appears in a
# command line, an environment variable, or a file on disk - docker inspect and
# the process list would both show the first two.
read -rsp "    Password for local account '$USERNAME': " PW1; echo
read -rsp "    Repeat: " PW2; echo
[[ $PW1 == "$PW2" ]] || die "passwords do not match"
[[ -n $PW1 ]] || die "empty password; use a password or edit the template for a blank account"
PW_ENC=$(unattend_password "$PW1" "Password")
unset PW1 PW2

log "Starting the build container"
printf '%s\n' "$PW_ENC" | docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${CMD[@]}" --password-stdin
