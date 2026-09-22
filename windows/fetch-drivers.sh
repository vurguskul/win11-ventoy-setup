#!/usr/bin/env bash
#
# Host side of the driver fetch: run windows/fetch-drivers.py in the build
# container, with windows/drivers/ mounted writable.
#
# In the container because extracting a catalog .cab needs 7z, and the host is
# meant to need only docker. windows/drivers/ is mounted on a path of its own
# rather than through /repo, which stays read-only.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

IMAGE="${IMAGE:-win11-ventoy-build}"
MANIFEST="${1:-$ROOT/windows/drivers.txt}"
DEST="$ROOT/windows/drivers"

need docker
[[ -f $MANIFEST ]] || { info "no $(basename "$MANIFEST") - nothing to fetch"; exit 0; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  log "Building the $IMAGE container image"
  docker build -t "$IMAGE" -f "$ROOT/docker/Dockerfile" "$ROOT/docker"
}

mkdir -p "$DEST"
exec docker run --rm -i \
  --user "$(id -u):$(id -g)" \
  -v "$ROOT:/repo:ro" \
  -v "$DEST:/drivers" \
  -v "$MANIFEST:/manifest.txt:ro" \
  "$IMAGE" python3 /repo/windows/fetch-drivers.py /manifest.txt /drivers
