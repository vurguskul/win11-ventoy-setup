#!/usr/bin/env bash
#
# Grab the guest framebuffer from a running `make test-boot` VM over QMP.
#
# The VM runs with -display none, so without this the only way to see what it
# is doing is to attach a VNC viewer by hand. screendump writes the framebuffer
# straight out of QEMU, which works headlessly and can be done repeatedly to
# watch a boot progress.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

PORT="${QMP_PORT:-4444}"
OUT="${1:-/tmp/win11-ventoy-screen.png}"

need python3

python3 - "$PORT" "$OUT" <<'PYEOF'
import json, socket, sys

port, out = int(sys.argv[1]), sys.argv[2]
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
except OSError as e:
    sys.exit(f"cannot reach QMP on 127.0.0.1:{port} ({e}) -- is the VM running?")

f = sock.makefile("rwb")
f.readline()                                    # greeting banner

def cmd(obj):
    f.write((json.dumps(obj) + "\n").encode())
    f.flush()
    while True:
        line = f.readline()
        if not line:
            sys.exit("QMP connection closed")
        msg = json.loads(line)
        if "return" in msg or "error" in msg:   # skip async events
            return msg

cmd({"execute": "qmp_capabilities"})

# format= landed in QEMU 7.1; fall back to PPM on anything older.
r = cmd({"execute": "screendump", "arguments": {"filename": out, "format": "png"}})
if "error" in r:
    ppm = out.rsplit(".", 1)[0] + ".ppm"
    r = cmd({"execute": "screendump", "arguments": {"filename": ppm}})
    if "error" in r:
        sys.exit("screendump failed: " + r["error"].get("desc", str(r)))
    out = ppm

print(out)
PYEOF
