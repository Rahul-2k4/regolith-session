#!/bin/bash

set -Eeu -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

ipc_file="$workdir/session-ipc.bin"
exec 9>"$ipc_file"
export COSMIC_SESSION_SOCK=9
export WAYLAND_DISPLAY=wayland-1
export DISPLAY=:0

export REGOLITH_COSMIC_SESSION_HELPERS="$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic.sh"
source "$ROOT_DIR/usr/lib/regolith/regolith-session-cosmic-runtime"
regolith_cosmic_session_send_environment
exec 9>&-

python3 - "$ipc_file" <<'PY'
import json
import struct
import sys

data = open(sys.argv[1], "rb").read()
assert len(data) >= 2, data
length = struct.unpack("=H", data[:2])[0]
payload = data[2:]
assert length == len(payload), (length, len(payload))
assert json.loads(payload) == {
    "message": "set_env",
    "variables": {"WAYLAND_DISPLAY": "wayland-1", "DISPLAY": ":0"},
}, payload
PY

echo "COSMIC session IPC environment handshake: PASS"
